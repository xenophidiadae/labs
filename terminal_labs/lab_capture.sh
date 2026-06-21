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
  -w WINDOW_ID    terminal window id; if omitted, you will be asked to click the target window
  -l FILE         save command input/output to a text file
  --full-screen   capture the whole screen instead of the terminal window
  -h, --help      show this help

Notes:
  - Empty lines and lines starting with # are ignored.
  - The script literally types commands into the chosen terminal window via xdotool.
  - You can add post-actions after a command: vim test.txt ### wait=1; vim-quit
  - Supported post-actions: wait=N, key=KEY, type=TEXT, enter, vim-quit, vim-save-quit, confirm-install.
  - Install dependencies: xdotool + one of import/scrot/gnome-screenshot/maim.
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
    printf 'Wayland detected. xdotool cannot type/press Enter reliably here.\n' >&2
    printf 'Log into an X11/Xorg session for this script to work.\n' >&2
    exit 1
  fi
}

focus_target_window() {
  # Агрессивный перехват фокуса
  xdotool windowfocus --sync "$WINDOW_ID" 2>/dev/null || true
  xdotool windowactivate --sync "$WINDOW_ID" 2>/dev/null || true
  xdotool windowraise "$WINDOW_ID" 2>/dev/null || true
  sleep 0.5
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

split_command_and_actions() {
  local raw_line="$1"

  COMMAND_TEXT="$raw_line"
  ACTIONS_TEXT=''

  if [[ "$raw_line" == *' ### '* ]]; then
    COMMAND_TEXT="${raw_line%% ### *}"
    ACTIONS_TEXT="${raw_line#* ### }"
  fi

  COMMAND_TEXT="$(trim_whitespace "$COMMAND_TEXT")"
  ACTIONS_TEXT="$(trim_whitespace "$ACTIONS_TEXT")"
}

press_key() {
  local key_name="$1"

  focus_target_window
  xdotool key --clearmodifiers "$key_name"
}

type_text() {
  local text="$1"

  focus_target_window
  xdotool type --clearmodifiers --delay 25 "$text"
}

is_install_like_command() {
  local lower_command
  lower_command="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  [[ "$lower_command" =~ (^|[[:space:]])(apt|apt-get|yum|dnf|pacman|yay|paru|npm|pnpm|yarn|pip|pip3|composer|gem|cargo)[[:space:]].*(install|add)([[:space:]]|$) ]]
}

is_interactive_vim_command() {
  local lower_command
  lower_command="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  [[ "$lower_command" =~ ^[[:space:]]*(vim|nvim|vi)([[:space:]]|$) ]] && [[ ! "$lower_command" =~ (^|[[:space:]])-c([[:space:]]|$) ]]
}

run_named_action() {
  local action_name="$1"

  case "$action_name" in
    enter|return)
      press_key Return
      ;;
    vim-quit)
      press_key Escape
      sleep 0.2
      type_text ':q!'
      sleep 0.2
      press_key Return
      ;;
    vim-save-quit)
      press_key Escape
      sleep 0.2
      type_text ':wq'
      sleep 0.2
      press_key Return
      ;;
    confirm-install)
      press_key Return
      sleep 1
      ;;
    *)
      printf 'Unknown post-action: %s\n' "$action_name" >&2
      exit 1
      ;;
  esac
}

run_post_actions() {
  local actions_text="$1"
  local action
  local trimmed_action
  local key_name
  local typed_text
  local wait_seconds

  IFS=';' read -r -a action_list <<< "$actions_text"
  for action in "${action_list[@]}"; do
    trimmed_action="$(trim_whitespace "$action")"
    [[ -z "$trimmed_action" ]] && continue

    case "$trimmed_action" in
      wait=*)
        wait_seconds="${trimmed_action#wait=}"
        sleep "$wait_seconds"
        ;;
      key=*)
        key_name="${trimmed_action#key=}"
        key_name="$(trim_whitespace "$key_name")"
        press_key "$key_name"
        ;;
      type=*)
        typed_text="${trimmed_action#type=}"
        type_text "$typed_text"
        ;;
      *)
        run_named_action "$trimmed_action"
        ;;
    esac
  done
}

run_auto_actions() {
  local command_text="$1"

  if is_install_like_command "$command_text"; then
    run_named_action confirm-install
  fi

  if is_interactive_vim_command "$command_text"; then
    run_named_action vim-quit
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
[[ -z "$COMMANDS_BASENAME" ]] && COMMANDS_BASENAME='commands'
[[ -z "$LOG_FILE" ]] && LOG_FILE="$OUTPUT_DIR/${COMMANDS_BASENAME}_output.txt"

require_cmd xdotool
check_session
SCREENSHOT_TOOL="$(pick_screenshot_tool)"

# Если ID окна не передан, просим пользователя кликнуть по нужному окну
if [[ -z "$WINDOW_ID" || "$WINDOW_ID" == "0" ]]; then
  printf 'Please click on the target terminal window with your mouse...\n'
  WINDOW_ID="$(xdotool selectwindow)"
fi

mkdir -p "$OUTPUT_DIR"
: > "$LOG_FILE"

printf 'Using window id: %s\n' "$WINDOW_ID"
printf 'Using screenshot tool: %s\n' "$SCREENSHOT_TOOL"
printf 'Saving screenshots to: %s\n' "$OUTPUT_DIR"
printf 'Saving command log to: %s\n' "$LOG_FILE"
printf 'Starting in 3 seconds. DO NOT touch the mouse or keyboard...\n'
sleep 3

counter=1
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  command_line="${raw_line%%$'\r'}"

  if [[ -z "$command_line" || "$command_line" =~ ^[[:space:]]*# ]]; then
    continue
  fi

  split_command_and_actions "$command_line"

  if [[ -z "$COMMAND_TEXT" ]]; then
    continue
  fi

  input_file=$(printf '%02d_%s_input.png' "$counter" "$COMMANDS_BASENAME")
  output_file=$(printf '%02d_%s_output.png' "$counter" "$COMMANDS_BASENAME")
  input_target="$OUTPUT_DIR/$input_file"
  output_target="$OUTPUT_DIR/$output_file"

  printf '[%02d] $ %s\n' "$counter" "$COMMAND_TEXT" >> "$LOG_FILE"

  # 1. Захватываем окно
  focus_target_window
  
  # 2. Очищаем строку в целевом терминале (Ctrl+U)
  xdotool key --clearmodifiers ctrl+u
  sleep 0.2
  
  # 3. Печатаем команду
  xdotool type --clearmodifiers --delay 25 "$COMMAND_TEXT"
  sleep 0.2
  
  # 4. Скриншот ДО нажатия Enter
  take_screenshot "$input_target"
  
  # 5. Нажимаем Enter в целевом окне
  xdotool key --clearmodifiers Return

  # 6. Ждем выполнения команды и делаем скриншот ПОСЛЕ
  sleep "$DELAY_SECONDS"

  if [[ -n "$ACTIONS_TEXT" ]]; then
    run_post_actions "$ACTIONS_TEXT"
  else
    run_auto_actions "$COMMAND_TEXT"
  fi

  take_screenshot "$output_target"

  counter=$((counter + 1))
done < "$COMMANDS_FILE"

printf 'Done. Captured %d screenshot(s).\n' $(((counter - 1) * 2))
