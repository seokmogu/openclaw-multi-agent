#!/bin/sh
set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
export PROJECT_ROOT

. "$PROJECT_ROOT/tools/cli/common.sh"

STATE_FILE="$STATE_DIR/infra_credentials.json"
KNOWN_PROVIDERS="aws gcp vercel supabase"

usage() {
    cat >&2 <<EOF
Usage:
  $(basename "$0") connect <provider> [provider-option]
  $(basename "$0") status
  $(basename "$0") validate
  $(basename "$0") disconnect <provider>

Providers:
  aws [role-arn]
  gcp [project-id]
  vercel
  supabase [project-ref]
EOF
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command not found: $1"
        return 1
    fi
}

null_if_empty() {
    if [ -n "$1" ]; then
        printf "%s" "$1"
    else
        printf "__NULL__"
    fi
}

ensure_state_file() {
    if [ ! -d "$STATE_DIR" ]; then
        mkdir -p "$STATE_DIR"
    fi

    if [ ! -f "$STATE_FILE" ]; then
        cat > "$STATE_FILE" <<'EOF'
{
  "schema_version": 1,
  "providers": {},
  "last_updated": null
}
EOF
    fi
}

write_provider_record() {
    provider="$1"
    shift

    ensure_state_file

    python3 - "$STATE_FILE" "$provider" "$@" <<'PY'
import json
import sys
from datetime import datetime, timezone

state_file = sys.argv[1]
provider = sys.argv[2]
updates = sys.argv[3:]

defaults = {
    "aws": {
        "status": "inactive",
        "auth_method": "access-key",
        "region": "ap-northeast-2",
        "role_arn": None,
        "expires_at": None,
        "auto_refresh": True,
        "discovered_services": [],
        "connected_at": None,
        "last_validated": None,
    },
    "gcp": {
        "status": "inactive",
        "auth_method": "adc",
        "project_id": None,
        "region": None,
        "auto_refresh": True,
        "discovered_services": [],
        "connected_at": None,
        "last_validated": None,
    },
    "vercel": {
        "status": "inactive",
        "auth_method": "token",
        "team_id": None,
        "projects": [],
        "connected_at": None,
        "last_validated": None,
    },
    "supabase": {
        "status": "inactive",
        "auth_method": "access-token",
        "project_ref": None,
        "branch_enabled": False,
        "connected_at": None,
        "last_validated": None,
    },
}

if provider not in defaults:
    raise SystemExit(f"Unknown provider: {provider}")

try:
    with open(state_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    data = {"schema_version": 1, "providers": {}, "last_updated": None}

if not isinstance(data, dict):
    data = {"schema_version": 1, "providers": {}, "last_updated": None}

providers = data.get("providers")
if not isinstance(providers, dict):
    providers = {}

record = defaults[provider].copy()
existing = providers.get(provider)
if isinstance(existing, dict):
    record.update(existing)

for item in updates:
    if "=" not in item:
        continue
    key, value = item.split("=", 1)
    if key.endswith("_json"):
        record[key[:-5]] = json.loads(value)
    elif value == "__NULL__":
        record[key] = None
    elif value == "__KEEP__":
        continue
    elif value == "true":
        record[key] = True
    elif value == "false":
        record[key] = False
    else:
        record[key] = value

providers[provider] = record
data["schema_version"] = 1
data["providers"] = providers
data["last_updated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

with open(state_file, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

get_provider_field() {
    ensure_state_file

    python3 - "$STATE_FILE" "$1" "$2" <<'PY'
import json
import sys

state_file, provider, field = sys.argv[1:4]

try:
    with open(state_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    raise SystemExit(0)

record = data.get("providers", {}).get(provider, {})
value = record.get(field)

if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, list):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

list_active_providers() {
    ensure_state_file

    python3 - "$STATE_FILE" <<'PY'
import json
import sys

known = ["aws", "gcp", "vercel", "supabase"]

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    raise SystemExit(0)

providers = data.get("providers", {})
for name in known:
    record = providers.get(name, {})
    if isinstance(record, dict) and record.get("status") == "active":
        print(name)
PY
}

print_status_table() {
    ensure_state_file

    python3 - "$STATE_FILE" <<'PY'
import json
import sys

known = ["aws", "gcp", "vercel", "supabase"]
defaults = {
    "aws": {
        "status": "inactive",
        "auth_method": "access-key",
        "region": "ap-northeast-2",
        "role_arn": None,
        "last_validated": None,
        "projects": [],
    },
    "gcp": {
        "status": "inactive",
        "auth_method": "adc",
        "project_id": None,
        "region": None,
        "last_validated": None,
        "projects": [],
    },
    "vercel": {
        "status": "inactive",
        "auth_method": "token",
        "team_id": None,
        "projects": [],
        "last_validated": None,
    },
    "supabase": {
        "status": "inactive",
        "auth_method": "access-token",
        "project_ref": None,
        "branch_enabled": False,
        "last_validated": None,
        "projects": [],
    },
}

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

providers = data.get("providers", {})
rows = []
for name in known:
    record = defaults[name].copy()
    current = providers.get(name)
    if isinstance(current, dict):
        record.update(current)

    if name == "aws":
        detail = record.get("role_arn") or record.get("region") or "-"
    elif name == "gcp":
        detail = record.get("project_id") or record.get("region") or "-"
    elif name == "vercel":
        team_id = record.get("team_id") or "-"
        detail = f"team={team_id} projects={len(record.get('projects') or [])}"
    else:
        project_ref = record.get("project_ref") or "-"
        branches = "true" if record.get("branch_enabled") else "false"
        detail = f"ref={project_ref} branches={branches}"

    rows.append(
        [
            name,
            record.get("status") or "-",
            record.get("auth_method") or "-",
            detail,
            record.get("last_validated") or "-",
        ]
    )

headers = ["provider", "status", "auth_method", "detail", "last_validated"]
widths = [len(header) for header in headers]
for row in rows:
    for index, value in enumerate(row):
        widths[index] = max(widths[index], len(str(value)))

header_line = "  ".join(header.ljust(widths[index]) for index, header in enumerate(headers))
separator_line = "  ".join("-" * widths[index] for index in range(len(headers)))

print(header_line)
print(separator_line)
for row in rows:
    print("  ".join(str(value).ljust(widths[index]) for index, value in enumerate(row)))
PY
}

timestamp_is_expired() {
    if [ -z "$1" ]; then
        return 1
    fi

    python3 - "$1" <<'PY'
import sys
from datetime import datetime, timezone

value = sys.argv[1]
try:
    expires_at = datetime.fromisoformat(value.replace("Z", "+00:00"))
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if expires_at <= datetime.now(timezone.utc) else 1)
PY
}

detect_aws_auth_method() {
    role_arn="$1"

    if [ -n "$role_arn" ]; then
        printf "assume-role"
        return 0
    fi

    if [ -n "${AWS_ACCESS_KEY_ID:-}" ] || [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        printf "access-key"
        return 0
    fi

    sso_start_url=$(aws configure get sso_start_url 2>/dev/null || true)
    sso_session=$(aws configure get sso_session 2>/dev/null || true)
    if [ -n "$sso_start_url" ] || [ -n "$sso_session" ]; then
        printf "sso"
        return 0
    fi

    printf "access-key"
}

detect_gcp_auth_method() {
    active_account="$1"

    case "$active_account" in
        *@*.gserviceaccount.com|*.gserviceaccount.com)
            printf "service-account"
            return 0
            ;;
    esac

    set +e
    gcloud auth application-default print-access-token >/dev/null 2>&1
    has_adc=$?
    set -e

    if [ "$has_adc" -eq 0 ] && [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
        printf "adc"
    elif [ "$has_adc" -eq 0 ] && [ -z "$active_account" ]; then
        printf "adc"
    else
        printf "oauth"
    fi
}

discover_vercel_projects_json() {
    set +e
    output=$(vercel project ls --token "$VERCEL_TOKEN" 2>/dev/null)
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        output=$(vercel projects ls --token "$VERCEL_TOKEN" 2>/dev/null)
        exit_code=$?
    fi
    set -e

    if [ "$exit_code" -ne 0 ]; then
        return 1
    fi

    printf "%s\n" "$output" | python3 - <<'PY'
import json
import re
import sys

ansi_re = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
skip_prefixes = (
    "Vercel CLI",
    "Fetching ",
    ">",
    "Project Name",
    "Name",
    "Inspect",
)

projects = []
seen = set()

for raw_line in sys.stdin.read().splitlines():
    line = ansi_re.sub("", raw_line).strip()
    if not line:
        continue
    if line.startswith(skip_prefixes):
        continue
    if set(line) == {"-"}:
        continue
    parts = [part.strip() for part in re.split(r"\s{2,}", line) if part.strip()]
    if not parts:
        continue
    candidate = parts[0]
    if candidate in seen:
        continue
    if candidate.lower() in {"project", "projects", "name"}:
        continue
    seen.add(candidate)
    projects.append(candidate)

print(json.dumps(projects, separators=(",", ":")))
PY
}

list_supabase_projects_json() {
    set +e
    output=$(supabase projects list --output json 2>/dev/null)
    exit_code=$?
    set -e

    if [ "$exit_code" -eq 0 ] && [ -n "$output" ]; then
        printf "%s" "$output" | python3 - <<'PY'
import json
import sys

raw = json.load(sys.stdin)
if isinstance(raw, dict):
    raw = raw.get("projects") or raw.get("data") or []

projects = []
for item in raw if isinstance(raw, list) else []:
    if not isinstance(item, dict):
        continue
    ref = item.get("ref") or item.get("reference_id") or item.get("project_ref") or item.get("id")
    name = item.get("name") or item.get("project_name")
    if ref:
        projects.append({"ref": ref, "name": name})

print(json.dumps(projects, separators=(",", ":")))
PY
        return 0
    fi

    set +e
    output=$(supabase projects list 2>/dev/null)
    exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ]; then
        return 1
    fi

    printf "%s\n" "$output" | python3 - <<'PY'
import json
import re
import sys

projects = []
seen = set()
for raw_line in sys.stdin.read().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("LINKED") or line.startswith("NAME"):
        continue
    if set(line) == {"-"}:
        continue
    ref_match = re.search(r"\b[a-z0-9]{8,}\b", line)
    if not ref_match:
        continue
    ref = ref_match.group(0)
    if ref in seen:
        continue
    seen.add(ref)
    projects.append({"ref": ref, "name": None})

print(json.dumps(projects, separators=(",", ":")))
PY
}

supabase_project_exists() {
    projects_json="$1"
    project_ref="$2"

    python3 - "$projects_json" "$project_ref" <<'PY'
import json
import sys

projects = json.loads(sys.argv[1])
project_ref = sys.argv[2]

for item in projects:
    if isinstance(item, dict) and item.get("ref") == project_ref:
        raise SystemExit(0)

raise SystemExit(1)
PY
}

supabase_branch_enabled() {
    set +e
    output=$(supabase branches list --project-ref "$1" --output json 2>/dev/null)
    exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ] || [ -z "$output" ]; then
        printf "false"
        return 0
    fi

    printf "%s" "$output" | python3 - <<'PY'
import json
import sys

raw = json.load(sys.stdin)
if isinstance(raw, dict):
    raw = raw.get("branches") or raw.get("data") or []

enabled = isinstance(raw, list) and len(raw) > 0
print("true" if enabled else "false")
PY
}

connect_aws() {
    role_arn="${1:-${AWS_ROLE_ARN:-}}"

    require_command aws

    set +e
    aws sts get-caller-identity --output json >/dev/null 2>&1
    exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ]; then
        log_error "AWS authentication failed"
        return 1
    fi

    region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    if [ -z "$region" ]; then
        region=$(aws configure get region 2>/dev/null || true)
    fi
    if [ -z "$region" ]; then
        region="ap-northeast-2"
    fi

    auth_method=$(detect_aws_auth_method "$role_arn")
    expires_at="__NULL__"

    if [ -n "$role_arn" ]; then
        session_name="infra-connect-$(date +%s)"
        set +e
        assume_output=$(aws sts assume-role --role-arn "$role_arn" --role-session-name "$session_name" --duration-seconds "${AWS_ASSUME_ROLE_DURATION:-3600}" --output json 2>/dev/null)
        exit_code=$?
        set -e

        if [ "$exit_code" -ne 0 ]; then
            log_error "AWS assume-role failed for $role_arn"
            return 1
        fi

        expires_at=$(printf "%s" "$assume_output" | python3 -c 'import json, sys; data = json.load(sys.stdin); print(data.get("Credentials", {}).get("Expiration") or "")')
        if [ -z "$expires_at" ]; then
            expires_at="__NULL__"
        fi
    fi

    now=$(timestamp_iso)
    write_provider_record aws \
        "status=active" \
        "auth_method=$auth_method" \
        "region=$region" \
        "role_arn=$(null_if_empty "$role_arn")" \
        "expires_at=$expires_at" \
        "auto_refresh=true" \
        'discovered_services_json=["sts"]' \
        "connected_at=$now" \
        "last_validated=$now"

    log_info "AWS connection validated"
}

validate_aws() {
    require_command aws

    role_arn=$(get_provider_field aws role_arn)
    auth_method=$(get_provider_field aws auth_method)
    stored_region=$(get_provider_field aws region)
    stored_expiry=$(get_provider_field aws expires_at)
    now=$(timestamp_iso)

    if [ -n "$stored_region" ]; then
        AWS_REGION="$stored_region"
        export AWS_REGION
    fi

    set +e
    aws sts get-caller-identity --output json >/dev/null 2>&1
    exit_code=$?
    set -e

    if [ "$exit_code" -eq 0 ] && [ "$auth_method" = "assume-role" ] && [ -n "$role_arn" ]; then
        session_name="infra-validate-$(date +%s)"
        set +e
        assume_output=$(aws sts assume-role --role-arn "$role_arn" --role-session-name "$session_name" --duration-seconds "${AWS_ASSUME_ROLE_DURATION:-3600}" --output json 2>/dev/null)
        exit_code=$?
        set -e

        if [ "$exit_code" -eq 0 ]; then
            stored_expiry=$(printf "%s" "$assume_output" | python3 -c 'import json, sys; data = json.load(sys.stdin); print(data.get("Credentials", {}).get("Expiration") or "")')
            if [ -z "$stored_expiry" ]; then
                stored_expiry="__NULL__"
            fi
        fi
    fi

    if [ "$exit_code" -eq 0 ]; then
        write_provider_record aws \
            "status=active" \
            "expires_at=$(null_if_empty "$stored_expiry")" \
            'discovered_services_json=["sts"]' \
            "last_validated=$now"
        log_info "AWS connection revalidated"
        return 0
    fi

    status="inactive"
    if [ -n "$stored_expiry" ] && timestamp_is_expired "$stored_expiry"; then
        status="expired"
    fi

    write_provider_record aws \
        "status=$status" \
        "expires_at=$(null_if_empty "$stored_expiry")" \
        "last_validated=$now"

    log_error "AWS validation failed"
    return 1
}

connect_gcp() {
    requested_project="$1"

    require_command gcloud

    set +e
    active_account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)
    exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ] || [ -z "$active_account" ]; then
        log_error "GCP authentication failed"
        return 1
    fi

    project_id="$requested_project"
    if [ -z "$project_id" ]; then
        project_id=$(gcloud config get project 2>/dev/null || true)
    fi
    if [ -z "$project_id" ]; then
        project_id=$(gcloud config get-value project 2>/dev/null || true)
    fi
    if [ -z "$project_id" ]; then
        log_error "No active GCP project configured"
        return 1
    fi

    set +e
    gcloud projects describe "$project_id" --format='value(projectNumber)' >/dev/null 2>&1
    exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ]; then
        log_error "GCP project validation failed for $project_id"
        return 1
    fi

    region="${GOOGLE_CLOUD_REGION:-${CLOUDSDK_COMPUTE_REGION:-}}"
    if [ -z "$region" ]; then
        region=$(gcloud config get compute/region 2>/dev/null || true)
    fi
    if [ -z "$region" ]; then
        region=$(gcloud config get-value compute/region 2>/dev/null || true)
    fi

    auth_method=$(detect_gcp_auth_method "$active_account")
    now=$(timestamp_iso)

    write_provider_record gcp \
        "status=active" \
        "auth_method=$auth_method" \
        "project_id=$project_id" \
        "region=$(null_if_empty "$region")" \
        "auto_refresh=true" \
        'discovered_services_json=[]' \
        "connected_at=$now" \
        "last_validated=$now"

    log_info "GCP connection validated"
}

validate_gcp() {
    require_command gcloud

    project_id=$(get_provider_field gcp project_id)
    now=$(timestamp_iso)

    set +e
    active_account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)
    exit_code=$?
    set -e

    if [ "$exit_code" -eq 0 ] && [ -n "$active_account" ] && [ -n "$project_id" ]; then
        set +e
        gcloud projects describe "$project_id" --format='value(projectNumber)' >/dev/null 2>&1
        exit_code=$?
        set -e
    else
        exit_code=1
    fi

    if [ "$exit_code" -eq 0 ]; then
        auth_method=$(detect_gcp_auth_method "$active_account")
        write_provider_record gcp \
            "status=active" \
            "auth_method=$auth_method" \
            "last_validated=$now"
        log_info "GCP connection revalidated"
        return 0
    fi

    write_provider_record gcp \
        "status=inactive" \
        "last_validated=$now"

    log_error "GCP validation failed"
    return 1
}

connect_vercel() {
    require_command vercel

    if [ -z "${VERCEL_TOKEN:-}" ]; then
        log_error "VERCEL_TOKEN environment variable is required"
        return 1
    fi

    set +e
    vercel whoami --token "$VERCEL_TOKEN" >/dev/null 2>&1
    exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ]; then
        log_error "Vercel authentication failed"
        return 1
    fi

    if ! projects_json=$(discover_vercel_projects_json); then
        log_error "Vercel project discovery failed"
        return 1
    fi

    team_id="${VERCEL_TEAM_ID:-${VERCEL_ORG_ID:-}}"
    now=$(timestamp_iso)

    write_provider_record vercel \
        "status=active" \
        "auth_method=token" \
        "team_id=$(null_if_empty "$team_id")" \
        "projects_json=$projects_json" \
        "connected_at=$now" \
        "last_validated=$now"

    log_info "Vercel connection validated"
}

validate_vercel() {
    require_command vercel

    if [ -z "${VERCEL_TOKEN:-}" ]; then
        log_error "VERCEL_TOKEN environment variable is required"
        return 1
    fi

    now=$(timestamp_iso)

    set +e
    vercel whoami --token "$VERCEL_TOKEN" >/dev/null 2>&1
    exit_code=$?
    set -e

    if [ "$exit_code" -eq 0 ] && projects_json=$(discover_vercel_projects_json); then
        team_id="${VERCEL_TEAM_ID:-${VERCEL_ORG_ID:-}}"
        write_provider_record vercel \
            "status=active" \
            "team_id=$(null_if_empty "$team_id")" \
            "projects_json=$projects_json" \
            "last_validated=$now"
        log_info "Vercel connection revalidated"
        return 0
    fi

    write_provider_record vercel \
        "status=inactive" \
        "projects_json=[]" \
        "last_validated=$now"

    log_error "Vercel validation failed"
    return 1
}

connect_supabase() {
    project_ref="${1:-${SUPABASE_PROJECT_REF:-}}"

    require_command supabase

    if ! projects_json=$(list_supabase_projects_json); then
        log_error "Supabase project discovery failed"
        return 1
    fi

    if [ -z "$project_ref" ]; then
        project_ref=$(python3 - "$projects_json" <<'PY'
import json
import sys

projects = json.loads(sys.argv[1])
if len(projects) == 1 and isinstance(projects[0], dict):
    print(projects[0].get("ref") or "")
else:
    print("")
PY
)
    fi

    if [ -z "$project_ref" ]; then
        log_error "Supabase project ref is required when multiple projects are available"
        return 1
    fi

    if ! supabase_project_exists "$projects_json" "$project_ref"; then
        log_error "Supabase project ref not found: $project_ref"
        return 1
    fi

    branch_enabled=$(supabase_branch_enabled "$project_ref")
    now=$(timestamp_iso)

    write_provider_record supabase \
        "status=active" \
        "auth_method=access-token" \
        "project_ref=$project_ref" \
        "branch_enabled=$branch_enabled" \
        "connected_at=$now" \
        "last_validated=$now"

    log_info "Supabase connection validated"
}

validate_supabase() {
    require_command supabase

    project_ref=$(get_provider_field supabase project_ref)
    now=$(timestamp_iso)

    if [ -z "$project_ref" ]; then
        write_provider_record supabase \
            "status=inactive" \
            "last_validated=$now"
        log_error "Supabase validation failed: project ref missing"
        return 1
    fi

    if projects_json=$(list_supabase_projects_json) && supabase_project_exists "$projects_json" "$project_ref"; then
        branch_enabled=$(supabase_branch_enabled "$project_ref")
        write_provider_record supabase \
            "status=active" \
            "branch_enabled=$branch_enabled" \
            "last_validated=$now"
        log_info "Supabase connection revalidated"
        return 0
    fi

    write_provider_record supabase \
        "status=inactive" \
        "last_validated=$now"

    log_error "Supabase validation failed"
    return 1
}

disconnect_provider() {
    provider="$1"
    now=$(timestamp_iso)

    case "$provider" in
        aws)
            write_provider_record aws \
                "status=inactive" \
                "expires_at=__NULL__" \
                'discovered_services_json=[]' \
                "connected_at=__NULL__" \
                "last_validated=$now"
            ;;
        gcp)
            write_provider_record gcp \
                "status=inactive" \
                'discovered_services_json=[]' \
                "connected_at=__NULL__" \
                "last_validated=$now"
            ;;
        vercel)
            write_provider_record vercel \
                "status=inactive" \
                'projects_json=[]' \
                "connected_at=__NULL__" \
                "last_validated=$now"
            ;;
        supabase)
            write_provider_record supabase \
                "status=inactive" \
                "branch_enabled=false" \
                "connected_at=__NULL__" \
                "last_validated=$now"
            ;;
        *)
            log_error "Unsupported provider: $provider"
            return 1
            ;;
    esac

    log_info "$provider disconnected"
}

validate_all() {
    ensure_state_file

    active_providers=$(list_active_providers)
    if [ -z "$active_providers" ]; then
        log_info "No active providers to validate"
        print_status_table
        return 0
    fi

    failures=0
    for provider in $active_providers; do
        set +e
        case "$provider" in
            aws)
                validate_aws
                ;;
            gcp)
                validate_gcp
                ;;
            vercel)
                validate_vercel
                ;;
            supabase)
                validate_supabase
                ;;
        esac
        exit_code=$?
        set -e

        if [ "$exit_code" -ne 0 ]; then
            failures=$((failures + 1))
        fi
    done

    print_status_table

    if [ "$failures" -ne 0 ]; then
        return 1
    fi
}

ensure_state_file

case "${1:-}" in
    connect)
        if [ $# -lt 2 ]; then
            usage
            exit 1
        fi
        provider="$2"
        option="${3:-}"
        case "$provider" in
            aws)
                connect_aws "$option"
                ;;
            gcp)
                connect_gcp "$option"
                ;;
            vercel)
                connect_vercel
                ;;
            supabase)
                connect_supabase "$option"
                ;;
            *)
                log_error "Unsupported provider: $provider"
                exit 1
                ;;
        esac
        print_status_table
        ;;
    status)
        print_status_table
        ;;
    validate)
        validate_all
        ;;
    disconnect)
        if [ $# -lt 2 ]; then
            usage
            exit 1
        fi
        disconnect_provider "$2"
        print_status_table
        ;;
    *)
        usage
        exit 1
        ;;
esac
