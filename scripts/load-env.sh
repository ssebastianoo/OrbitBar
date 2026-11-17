# Sourced by build-app.sh and release.sh from the repository root. Reads .env (git-ignored): one NAME=value per line,
# optionally prefixed with `export` and with the value in single or double quotes. Blank lines and # comments are
# skipped, and a last line without a newline still counts. Variables already in the environment win, so CI is
# unaffected.
if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|\#*) continue ;; esac
    line="${line#export }"
    name="${line%%=*}"
    [ "$name" != "$line" ] || continue
    name="${name%"${name##*[![:space:]]}"}"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "warning: .env: skipping invalid line: $line" >&2
      continue
    fi
    if [ -z "${!name:-}" ]; then export "$name=$value"; fi
  done < .env
  unset line name value
fi
