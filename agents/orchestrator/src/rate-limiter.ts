import type { Request, Response, NextFunction, RequestHandler } from 'express';

// ---------------------------------------------------------------------------
// Types & Interfaces
// ---------------------------------------------------------------------------

/** Internal bucket tracking hits within a single fixed window. */
interface WindowEntry {
  count: number;
  windowStart: number;
}

/**
 * Configuration options accepted by the {@link rateLimiter} factory.
 */
export interface RateLimiterOptions {
  /**
   * Length of the fixed window in milliseconds.
   * @default 60_000 (1 minute)
   */
  windowMs?: number;

  /**
   * Maximum number of requests allowed per window per key.
   * @default 100
   */
  maxRequests?: number;

  /**
   * Synchronous function that derives a string key from the incoming request.
   * The key is used to bucket request counts (typically the client IP).
   *
   * **Important:** When running behind a reverse proxy you **must** enable
   * Express's `trust proxy` setting (`app.set('trust proxy', true)`) so that
   * `req.ip` reflects the real client address rather than the proxy's.
   *
   * @default (req) => req.ip ?? 'unknown'
   */
  keyGenerator?: (req: Request) => string;

  /**
   * Optional predicate evaluated **before** any rate-limit logic.
   * Return `true` to skip rate limiting for the matched request entirely
   * (e.g. health-check routes, internal traffic).
   *
   * @default () => false
   */
  skip?: (req: Request) => boolean;

  /**
   * When `true` the middleware reads `req.ip` which—if Express `trust proxy`
   * is configured—resolves to the leftmost `X-Forwarded-For` entry.
   *
   * This flag exists purely as documentation / a guard: if set to `true` but
   * `req.app.get('trust proxy')` is falsy a one-time warning is emitted.
   *
   * @default false
   */
  trustProxy?: boolean;

  /**
   * Custom handler invoked when a request exceeds the rate limit.
   * Receives the standard Express arguments plus a `retryAfterSeconds` value.
   * If not provided the middleware sends a JSON 429 response automatically.
   */
  handler?: (
    req: Request,
    res: Response,
    next: NextFunction,
    retryAfterSeconds: number,
  ) => void;
}

/**
 * The middleware function returned by {@link rateLimiter}, augmented with a
 * {@link RateLimiterMiddleware.destroy | destroy()} method that tears down
 * the internal cleanup timer and releases state.
 */
export interface RateLimiterMiddleware extends RequestHandler {
  /** Stop the background cleanup interval and clear all stored state. */
  destroy: () => void;
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

const DEFAULT_WINDOW_MS = 60_000;
const DEFAULT_MAX_REQUESTS = 100;
const CLEANUP_INTERVAL_MS = 30_000; // run eviction every 30 s

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/**
 * Creates an Express middleware that enforces a **fixed-window** rate limit.
 *
 * ### Algorithm
 *
 * Each unique key (derived via `keyGenerator`, defaulting to `req.ip`) is
 * assigned a counter that resets at the start of every fixed window of
 * `windowMs` milliseconds.  Once the counter exceeds `maxRequests` the
 * middleware responds with HTTP 429 and a `Retry-After` header.
 *
 * ### Response Headers (set on **every** response)
 *
 * | Header                  | Description                                      |
 * |-------------------------|--------------------------------------------------|
 * | `X-RateLimit-Limit`     | The configured `maxRequests` value.               |
 * | `X-RateLimit-Remaining` | Requests remaining in the current window.         |
 * | `X-RateLimit-Reset`     | UTC epoch **seconds** when the window resets.     |
 *
 * ### Trust Proxy
 *
 * When your Express app sits behind a load balancer or reverse proxy you
 * **must** call `app.set('trust proxy', true)` (or a more specific value)
 * so that `req.ip` returns the real client address.  Failing to do so will
 * cause all clients to share a single bucket (the proxy's IP).
 *
 * @example
 * ```ts
 * import express from 'express';
 * import { rateLimiter } from './rate-limiter';
 *
 * const app = express();
 * app.set('trust proxy', true);
 *
 * const limiter = rateLimiter({
 *   windowMs: 15 * 60 * 1000, // 15 minutes
 *   maxRequests: 200,
 *   trustProxy: true,
 *   skip: (req) => req.path === '/health',
 * });
 *
 * app.use(limiter);
 *
 * // Graceful shutdown
 * process.on('SIGTERM', () => limiter.destroy());
 * ```
 *
 * @param options - Configuration overrides (all optional).
 * @returns A {@link RateLimiterMiddleware} request handler with a `destroy()` method.
 */
export function rateLimiter(options: RateLimiterOptions = {}): RateLimiterMiddleware {
  const {
    windowMs = DEFAULT_WINDOW_MS,
    maxRequests = DEFAULT_MAX_REQUESTS,
    keyGenerator = (req: Request): string => req.ip ?? 'unknown',
    skip = (): boolean => false,
    trustProxy = false,
    handler,
  } = options;

  // ---- State ---------------------------------------------------------------

  const store = new Map<string, WindowEntry>();
  let trustProxyWarned = false;

  // ---- Cleanup timer -------------------------------------------------------

  const cleanupTimer: ReturnType<typeof setInterval> = setInterval(() => {
    const now = Date.now();
    for (const [key, entry] of store) {
      if (now - entry.windowStart >= windowMs) {
        store.delete(key);
      }
    }
  }, CLEANUP_INTERVAL_MS);

  // Allow the Node process to exit even if the timer is still active.
  if (cleanupTimer && typeof cleanupTimer === 'object' && 'unref' in cleanupTimer) {
    cleanupTimer.unref();
  }

  // ---- Middleware -----------------------------------------------------------

  const middleware: RateLimiterMiddleware = function rateLimiterMiddleware(
    req: Request,
    res: Response,
    next: NextFunction,
  ): void {
    // Optional skip predicate
    if (skip(req)) {
      next();
      return;
    }

    // Trust-proxy guard (one-time warning)
    if (trustProxy && !trustProxyWarned && !req.app.get('trust proxy')) {
      trustProxyWarned = true;
      console.warn(
        '[rate-limiter] trustProxy is enabled but Express "trust proxy" is not set. ' +
          'req.ip may resolve to the proxy address instead of the real client.',
      );
    }

    const now = Date.now();
    const key = keyGenerator(req);

    // Retrieve or initialise the window entry
    let entry = store.get(key);

    if (!entry || now - entry.windowStart >= windowMs) {
      // First request in a new window
      entry = { count: 1, windowStart: now };
      store.set(key, entry);
    } else {
      entry.count += 1;
    }

    // Compute header values
    const windowResetMs = entry.windowStart + windowMs;
    const windowResetSec = Math.ceil(windowResetMs / 1000);
    const remaining = Math.max(maxRequests - entry.count, 0);

    // Set rate-limit headers on every response
    res.setHeader('X-RateLimit-Limit', String(maxRequests));
    res.setHeader('X-RateLimit-Remaining', String(remaining));
    res.setHeader('X-RateLimit-Reset', String(windowResetSec));

    // Exceeded?
    if (entry.count > maxRequests) {
      const retryAfterSeconds = Math.ceil((windowResetMs - now) / 1000);
      res.setHeader('Retry-After', String(retryAfterSeconds));

      if (handler) {
        handler(req, res, next, retryAfterSeconds);
        return;
      }

      res.status(429).json({
        error: 'Too Many Requests',
        retryAfter: retryAfterSeconds,
      });
      return;
    }

    next();
  } as RateLimiterMiddleware;

  // ---- destroy() -----------------------------------------------------------

  middleware.destroy = (): void => {
    clearInterval(cleanupTimer);
    store.clear();
  };

  return middleware;
}

export default rateLimiter;
