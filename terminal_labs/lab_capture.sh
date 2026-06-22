#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./lab_capture.sh [-f commands.txt|directory] [-o screenshots] [-d 2] [-w 0] [--full-screen] [-l output.txt]

Options:
  -f PATH         file with commands or directory with .txt files;
                  if omitted, all .txt files in the current directory are processed
  -o DIR          output directory for screenshots (default: ./screenshots)
  -d SECONDS      delay after each command before screenshot (default: 2)
  -w WINDOW_ID    terminal window id; if omitted, you will be asked to click the target window
  -l FILE         save command input/output to a text file;
                  for multiple command files, everything is appended into one log
  --full-screen   capture the whole screen instead of the terminal window
  --click-focus   click inside the terminal before every command
  --paste-input   enter commands via clipboard paste instead of xdotool type
  -h, --help      show this help

Notes:
  - Empty lines and lines starting with # are ignored.
  - When several .txt files are found, they are processed one by one in name order.
  - The terminal is cleared between command files.
  - The script literally types commands into the chosen terminal window via xdotool.
  - Some terminals (GNOME Terminal, Ghostty) may need click-to-focus behavior.
  - Some terminals also ignore synthetic typing; for them the script can paste commands.
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
  xdotool windowfocus --sync "$WINDOW_ID" 2>/dev/null || true
  xdotool windowactivate --sync "$WINDOW_ID" 2>/dev/null || true
  xdotool windowraise "$WINDOW_ID" 2>/dev/null || true
  sleep 0.5
}

click_target_window() {
  focus_target_window

  xdotool mousemove --window "$WINDOW_ID" 120 120 click 1 2>/dev/null || \
    xdotool click 1 2>/dev/null || true
  sleep 0.2
}

prepare_target_window() {
  focus_target_window

  if [[ "$CLICK_FOCUS" == "1" ]]; then
    click_target_window
  fi
}

set_clipboard_text() {
  local text="$1"

  if command -v xclip >/dev/null 2>&1; then
    printf '%s' "$text" | xclip -selection clipboard
    return 0
  fi

  if command -v xsel >/dev/null 2>&1; then
    printf '%s' "$text" | xsel --clipboard --input
    return 0
  fi

  printf 'Paste input mode requires xclip or xsel.\n' >&2
  exit 1
}

paste_text() {
  local text="$1"

  prepare_target_window
  set_clipboard_text "$text"
  sleep 0.1

  xdotool key --window "$WINDOW_ID" --clearmodifiers ctrl+shift+v 2>/dev/null || true
  sleep 0.1
  xdotool key --window "$WINDOW_ID" --clearmodifiers shift+Insert 2>/dev/null || true
  sleep 0.2
}

send_key() {
  local key_name="$1"

  prepare_target_window
  xdotool key --window "$WINDOW_ID" --clearmodifiers "$key_name" 2>/dev/null || \
    xdotool key --clearmodifiers "$key_name"
}

send_text() {
  local text="$1"

  if [[ "$INPUT_MODE" == 'paste' ]]; then
    paste_text "$text"
    return 0
  fi

  prepare_target_window
  xdotool type --window "$WINDOW_ID" --clearmodifiers --delay 25 "$text" 2>/dev/null || \
    xdotool type --clearmodifiers --delay 25 "$text"
}

detect_click_focus_need() {
  local window_name
  local window_class

  window_name="$(xdotool getwindowname "$WINDOW_ID" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  window_class="$(xprop -id "$WINDOW_ID" WM_CLASS 2>/dev/null | tr '[:upper:]' '[:lower:]')"

  if [[ "$window_name" == *ghostty* || "$window_name" == *gnome-terminal* || "$window_class" == *ghostty* || "$window_class" == *gnome-terminal* ]]; then
    CLICK_FOCUS='1'
    INPUT_MODE='paste'
  fi
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

  send_key "$key_name"
}

type_text() {
  local text="$1"

  send_text "$text"
}

sanitize_basename() {
  local base_name="$1"

  base_name="${base_name%.*}"
  base_name="$(printf '%s' "$base_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')"
  [[ -z "$base_name" ]] && base_name='commands'
  printf '%s\n' "$base_name"
}

append_log_header() {
  local commands_file="$1"

  printf '===== %s =====\n' "$commands_file" >> "$CURRENT_LOG_FILE"
}

clear_terminal_window() {
  type_text 'clear'
  press_key Return
  sleep 0.4
}

collect_command_files() {
  local input_path="$1"
  local resolved_path

  COMMAND_FILES=()

  if [[ -n "$input_path" ]]; then
    if [[ -d "$input_path" ]]; then
      while IFS= read -r file_path; do
        COMMAND_FILES+=("$file_path")
      done < <(find "$input_path" -maxdepth 1 -type f -name '*.txt' | sort)
    elif [[ -f "$input_path" ]]; then
      COMMAND_FILES+=("$input_path")
    else
      printf 'Commands path not found: %s\n' "$input_path" >&2
      exit 1
    fi
  else
    while IFS= read -r file_path; do
      COMMAND_FILES+=("$file_path")
    done < <(find . -maxdepth 1 -type f -name '*.txt' | sort)
  fi

  if [[ ${#COMMAND_FILES[@]} -eq 0 ]]; then
    resolved_path="${input_path:-.}"
    printf 'No .txt command files found in: %s\n' "$resolved_path" >&2
    exit 1
  fi
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

COMMANDS_PATH=''
OUTPUT_DIR='screenshots'
DELAY_SECONDS='2'
WINDOW_ID=''
FULL_SCREEN='0'
LOG_FILE=''
CURRENT_LOG_FILE=''
TOTAL_SCREENSHOTS=0
COMMAND_FILES=()
CLICK_FOCUS='0'
INPUT_MODE='type'

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)
      COMMANDS_PATH="$2"
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
    --click-focus)
      CLICK_FOCUS='1'
      shift
      ;;
    --paste-input)
      INPUT_MODE='paste'
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

collect_command_files "$COMMANDS_PATH"

require_cmd xdotool
require_cmd xprop
check_session
SCREENSHOT_TOOL="$(pick_screenshot_tool)"

if [[ -z "$WINDOW_ID" || "$WINDOW_ID" == "0" ]]; then
  printf 'Please click on the target terminal window with your mouse...\n'
  WINDOW_ID="$(xdotool selectwindow)"
fi

detect_click_focus_need

if [[ "$INPUT_MODE" == 'paste' ]]; then
  if ! command -v xclip >/dev/null 2>&1 && ! command -v xsel >/dev/null 2>&1; then
    printf 'Paste input mode needs xclip or xsel.\n' >&2
    exit 1
  fi
fi

mkdir -p "$OUTPUT_DIR"

if [[ -n "$LOG_FILE" ]]; then
  : > "$LOG_FILE"
fi

printf 'Using window id: %s\n' "$WINDOW_ID"
printf 'Using screenshot tool: %s\n' "$SCREENSHOT_TOOL"
printf 'Saving screenshots to: %s\n' "$OUTPUT_DIR"
if [[ -n "$LOG_FILE" ]]; then
  printf 'Saving command log to: %s\n' "$LOG_FILE"
fi
printf 'Click-to-focus mode: %s\n' "$CLICK_FOCUS"
printf 'Input mode: %s\n' "$INPUT_MODE"
printf 'Found command files: %d\n' "${#COMMAND_FILES[@]}"
printf 'Starting in 3 seconds. DO NOT touch the mouse or keyboard...\n'
sleep 3

for command_file in "${COMMAND_FILES[@]}"; do
  COMMANDS_BASENAME="$(sanitize_basename "$(basename "$command_file")")"

  if [[ -n "$LOG_FILE" ]]; then
    CURRENT_LOG_FILE="$LOG_FILE"
  else
    CURRENT_LOG_FILE="$OUTPUT_DIR/${COMMANDS_BASENAME}_output.txt"
    : > "$CURRENT_LOG_FILE"
  fi

  append_log_header "$command_file"
  printf 'Processing: %s\n' "$command_file"

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

    printf '[%02d] $ %s\n' "$counter" "$COMMAND_TEXT" >> "$CURRENT_LOG_FILE"

    prepare_target_window
    send_key ctrl+u
    sleep 0.2
    send_text "$COMMAND_TEXT"
    sleep 0.2

    take_screenshot "$input_target"
    send_key Return

    sleep "$DELAY_SECONDS"

    if [[ -n "$ACTIONS_TEXT" ]]; then
      run_post_actions "$ACTIONS_TEXT"
    else
      run_auto_actions "$COMMAND_TEXT"
    fi

    take_screenshot "$output_target"

    TOTAL_SCREENSHOTS=$((TOTAL_SCREENSHOTS + 2))
    counter=$((counter + 1))
  done < "$command_file"

  printf '\n' >> "$CURRENT_LOG_FILE"
  clear_terminal_window
done

printf 'Done. Captured %d screenshot(s) from %d file(s).\n' "$TOTAL_SCREENSHOTS" "${#COMMAND_FILES[@]}"
