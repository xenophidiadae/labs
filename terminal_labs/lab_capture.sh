#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./lab_capture.sh -f commands.txt [-o screenshots] [-d 2] [-w 0] [--full-screen] [-l output.txt]

Options:
  -f FILE         file with commands, one per line
  -o DIR          output directory for screenshots (default: ./screenshots)
  -d SECONDS      delay after each command before screenshot (default: 2)
  -w WINDOW_ID    terminal window id; if omitted, active window is used
  -l FILE         save command input/output to a text file
  --full-screen   capture the whole screen instead of the terminal window
  -h, --help      show this help

Notes:
  - Empty lines and lines starting with # are ignored.
  - The script literally types commands into the chosen terminal window via xdotool.
  - Run this script from one terminal, and choose a different terminal window as the target.
  - For each command it saves two screenshots: before Enter and after command output.
  - Install dependencies in the VM: xdotool + one of import/scrot/gnome-screenshot/maim.
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

check_session() {
  if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    printf 'Wayland detected. xdotool usually cannot type/press Enter reliably there.\n' >&2
    printf 'Log into an X11/Xorg session or use Wayland-specific tools.\n' >&2
    exit 1
  fi
}

pick_screenshot_tool() {
  for tool in import scrot gnome-screenshot maim; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '%s\n' "$tool"
      return 0
    fi
  done

  printf 'No screenshot tool found. Install ImageMagick, scrot, gnome-screenshot, or maim.\n' >&2
  exit 1
}

take_screenshot() {
  local target_file="$1"

  case "$SCREENSHOT_TOOL" in
    import)
      if [[ "$FULL_SCREEN" == "1" ]]; then
        import -window root "$target_file"
      else
        import -window "$WINDOW_ID" "$target_file"
      fi
      ;;
    scrot)
      scrot "$target_file"
      ;;
    gnome-screenshot)
      if [[ "$FULL_SCREEN" == "1" ]]; then
        gnome-screenshot -f "$target_file"
      else
        gnome-screenshot -w -f "$target_file"
      fi
      ;;
    maim)
      if [[ "$FULL_SCREEN" == "1" ]]; then
        maim "$target_file"
      else
        maim -i "$WINDOW_ID" "$target_file"
      fi
      ;;
  esac
}

COMMANDS_FILE=''
OUTPUT_DIR='screenshots'
DELAY_SECONDS='2'
WINDOW_ID=''
FULL_SCREEN='0'
COMMANDS_BASENAME=''
LOG_FILE=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)
      COMMANDS_FILE="$2"
      shift 2
      ;;
    -o)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -d)
      DELAY_SECONDS="$2"
      shift 2
      ;;
    -w)
      WINDOW_ID="$2"
      shift 2
      ;;
    -l)
      LOG_FILE="$2"
      shift 2
      ;;
    --full-screen)
      FULL_SCREEN='1'
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$COMMANDS_FILE" ]]; then
  printf 'You must pass -f commands.txt\n\n' >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$COMMANDS_FILE" ]]; then
  printf 'Commands file not found: %s\n' "$COMMANDS_FILE" >&2
  exit 1
fi

COMMANDS_BASENAME="$(basename "$COMMANDS_FILE")"
COMMANDS_BASENAME="${COMMANDS_BASENAME%.*}"
COMMANDS_BASENAME="$(printf '%s' "$COMMANDS_BASENAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')"

if [[ -z "$COMMANDS_BASENAME" ]]; then
  COMMANDS_BASENAME='commands'
fi

if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="$OUTPUT_DIR/${COMMANDS_BASENAME}_output.txt"
fi

require_cmd xdotool
check_session
SCREENSHOT_TOOL="$(pick_screenshot_tool)"

if [[ -z "$WINDOW_ID" || "$WINDOW_ID" == "0" ]]; then
  printf 'Click the target terminal window...\n'
  WINDOW_ID="$(xdotool selectwindow)"
fi

mkdir -p "$OUTPUT_DIR"

: > "$LOG_FILE"

printf 'Using window id: %s\n' "$WINDOW_ID"
printf 'Using screenshot tool: %s\n' "$SCREENSHOT_TOOL"
printf 'Saving screenshots to: %s\n' "$OUTPUT_DIR"
printf 'Saving command log to: %s\n' "$LOG_FILE"
printf 'Starting in 3 seconds...\n'
sleep 3

counter=1
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  command_line="${raw_line%%$'\r'}"

  if [[ -z "$command_line" || "$command_line" =~ ^[[:space:]]*# ]]; then
    continue
  fi

  input_file=$(printf '%02d_%s_input.png' "$counter" "$COMMANDS_BASENAME")
  output_file=$(printf '%02d_%s_output.png' "$counter" "$COMMANDS_BASENAME")
  input_target="$OUTPUT_DIR/$input_file"
  output_target="$OUTPUT_DIR/$output_file"

  printf '[%02d] %s\n' "$counter" "$command_line"
  printf '[%02d] $ %s\n' "$counter" "$command_line" >> "$LOG_FILE"

  xdotool windowactivate --sync "$WINDOW_ID"
  sleep 0.5
  xdotool key --clearmodifiers ctrl+u
  sleep 0.2
  xdotool type --clearmodifiers --delay 25 "$command_line"
  sleep 0.2
  take_screenshot "$input_target"
  xdotool key --clearmodifiers Return

  sleep "$DELAY_SECONDS"
  take_screenshot "$output_target"

  counter=$((counter + 1))
done < "$COMMANDS_FILE"

printf 'Done. Captured %d screenshot(s).\n' $(((counter - 1) * 2))
