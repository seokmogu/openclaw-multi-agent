#!/usr/bin/env python3
"""Patch PI SDK model catalog to add gpt-5.4 for openai-codex provider (ChatGPT Pro OAuth)."""

import shutil, glob

pattern = "/app/node_modules/.pnpm/@mariozechner+pi-ai@*/node_modules/@mariozechner/pi-ai/dist/models.generated.js"
files = glob.glob(pattern)
if not files:
    print("ERROR: models.generated.js not found")
    exit(1)

model_file = files[0]
print(f"Patching: {model_file}")

shutil.copy2(model_file, model_file + ".bak")

with open(model_file, "r") as f:
    content = f.read()

if '"gpt-5.4"' in content:
    print("SKIP: gpt-5.4 already exists")
    exit(0)

# gpt-5.4 entry for openai-codex provider (ChatGPT Pro OAuth via chatgpt.com/backend-api)
gpt54_codex = """
        "gpt-5.4": {
            id: "gpt-5.4",
            name: "GPT-5.4",
            api: "openai-codex-responses",
            provider: "openai-codex",
            baseUrl: "https://chatgpt.com/backend-api",
            reasoning: false,
            input: ["text", "image"],
            cost: {
                input: 2.5,
                output: 10,
                cacheRead: 0.25,
                cacheWrite: 0,
            },
            contextWindow: 1000000,
            maxTokens: 32768,
        },"""

# gpt-5.4 entry for standard openai provider (API key via api.openai.com)
gpt54_openai = """
        "gpt-5.4": {
            id: "gpt-5.4",
            name: "GPT-5.4",
            api: "openai-responses",
            provider: "openai",
            baseUrl: "https://api.openai.com/v1",
            reasoning: false,
            input: ["text", "image"],
            cost: {
                input: 2.5,
                output: 10,
                cacheRead: 0.25,
                cacheWrite: 0,
            },
            contextWindow: 1000000,
            maxTokens: 32768,
        },"""


def find_entry_end(text, start_idx):
    """Find the end position (after closing },) of a model entry starting at start_idx.

    start_idx must point to the opening quote of the KEY (e.g. "gpt-5.3-codex": {).
    We skip to the first '{' after the colon, then track depth from there.
    """
    # Find the opening { of the entry value (after the key and colon)
    brace_start = text.find("{", start_idx)
    if brace_start == -1 or brace_start > start_idx + 200:
        return -1

    depth = 1  # We're inside the entry's opening {
    for i in range(brace_start + 1, min(brace_start + 2000, len(text))):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                # Found the closing } of the entry
                j = i + 1
                while j < len(text) and text[j] in " \t\n":
                    j += 1
                if j < len(text) and text[j] == ",":
                    return j + 1
                return i + 1
    return -1


def is_property_key(content, idx):
    """Check if the match at idx is a property key (not an id: value).

    A property key has pattern: "key": {
    An id value has pattern: id: "key",
    """
    # Look ahead for ": {" pattern (property key)
    after = content[idx : idx + 100]
    # The key pattern: "gpt-5.3-codex": {
    # After the closing quote, should see `: {` (with possible whitespace)
    quote_end = after.find('"', 1)  # Find closing quote
    if quote_end == -1:
        return False
    rest = after[quote_end + 1 :].lstrip()
    return rest.startswith(": {") or rest.startswith(":{")


def insert_after_provider(content, provider_str, entry_text):
    """Insert gpt-5.4 entry after the last gpt-5.3 entry for a given provider."""
    # Try gpt-5.3-codex-spark first (it's the last entry), then gpt-5.3-codex
    for search_key in ['"gpt-5.3-codex-spark"', '"gpt-5.3-codex"']:
        search_start = 0
        last_match_end = -1

        while True:
            idx = content.find(search_key, search_start)
            if idx == -1:
                break
            # Only match property keys, not id: values
            if is_property_key(content, idx):
                region = content[idx : idx + 800]
                if provider_str in region:
                    end = find_entry_end(content, idx)
                    if end > 0:
                        last_match_end = end
            search_start = idx + 1

        if last_match_end > 0:
            return content[:last_match_end] + entry_text + content[last_match_end:]

    return None


# 1. Add to openai-codex provider (ChatGPT Pro OAuth)
result = insert_after_provider(content, 'provider: "openai-codex"', gpt54_codex)
if result:
    content = result
    print("Added gpt-5.4 to openai-codex provider")
else:
    print("WARNING: Could not find openai-codex provider section")

# 2. Add to standard openai provider (API key)
result = insert_after_provider(content, 'provider: "openai",', gpt54_openai)
if result:
    content = result
    print("Added gpt-5.4 to openai provider")
else:
    print("WARNING: Could not find openai provider section")

with open(model_file, "w") as f:
    f.write(content)

print("SUCCESS: gpt-5.4 patched into model catalog")
