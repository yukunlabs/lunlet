// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-33, AC-33.08, AC-33.09; US-04, AC-04.03, AC-04.05.
import Foundation

/// Lunlet-owned files of the Claude Code status-line integration, in Lunlet's Application Support directory.
/// Readings hold only the five-hour and seven-day percent used, reset times and the time they were observed.
public struct ClaudeStatusLineLocation: Equatable, Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL }
    public static var standard: Self {
        .init(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.lunlet/claude-status-line", isDirectory: true))
    }
    /// The installed command; a stable path, so Claude Code's setting survives Lunlet updates.
    public var script: URL { directory.appendingPathComponent("claude-status-line.sh") }
    /// The latest merged reading of each window.
    public var limits: URL { directory.appendingPathComponent("limits") }
    /// Seven-day readings for the forecast: on change or hourly, kept for eight days.
    public var weeklyLog: URL { directory.appendingPathComponent("weekly-readings.log") }
    /// The replaced `statusLine` value, its command for chaining and the installed value.
    public var backup: URL { directory.appendingPathComponent("previous-status-line.json") }

    /// The `statusLine.command` Lunlet writes: `/bin/sh` runs the script, so no executable bit is needed.
    public var command: String { "/bin/sh " + Self.quoted(script.path) }
    static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
}

/// The status-line command. POSIX `sh` with macOS's own `plutil`, `cat`, `date`, `tail`, `awk`, `mv` and `rm`:
/// no network, interpreter or package. It parses only `rate_limits.five_hour` and `rate_limits.seven_day`, keeps
/// the higher value of one window when sessions report it out of order, chains the replaced command and exits 0.
enum ClaudeStatusLineScript {
    static let source = #"""
    #!/bin/sh
    # Lunlet's Claude Code status line, installed only by Lunlet's explicit Connect plan limits action.
    # Refs: US-33, AC-33.08, AC-33.09.
    # Keeps only rate_limits.five_hour and rate_limits.seven_day used_percentage and resets_at, with the time they were
    # observed, in this directory; every other input field stays in memory and is discarded. Then runs the status line
    # it replaced with the same input and prints a compact limits line. Uses only macOS tools and always exits 0.
    umask 077
    set -f
    trap 'exit 0' HUP INT PIPE TERM
    lunlet_dir=${0%/*}
    case $lunlet_dir in /?*) ;; *) lunlet_dir= ;; esac
    lunlet_input=$(/bin/cat; printf .)
    lunlet_input=${lunlet_input%.}
    lunlet_now=$(/bin/date +%s 2>/dev/null)
    case $lunlet_now in [1-9]*) case $lunlet_now in *[!0-9]*) lunlet_now= ;; esac ;; *) lunlet_now= ;; esac

    # Without leading zeros, so arithmetic never reads a value as octal.
    lunlet_decimal() {
        lunlet_digits=$1
        while :; do case $lunlet_digits in 0?*) lunlet_digits=${lunlet_digits#0} ;; *) break ;; esac; done
    }
    # A 0...100 percentage as lunlet_text (truncated to six decimals) and lunlet_scaled (millionths, for comparison).
    lunlet_percent() {
        case $1 in ''|*[!0-9.]*|*.*.*|.*|*.) return 1 ;; esac
        lunlet_int=${1%%.*} lunlet_frac=
        case $1 in *.*) lunlet_frac=${1#*.} ;; esac
        [ ${#lunlet_int} -le 3 ] && [ ${#lunlet_frac} -le 24 ] || return 1
        while [ ${#lunlet_frac} -gt 6 ]; do lunlet_frac=${lunlet_frac%?}; done
        lunlet_decimal "$lunlet_int"; lunlet_int=$lunlet_digits
        while [ ${#lunlet_frac} -lt 6 ]; do lunlet_frac=${lunlet_frac}0; done
        lunlet_decimal "$lunlet_int$lunlet_frac"; lunlet_scaled=$lunlet_digits
        [ "$lunlet_scaled" -le 100000000 ] || return 1
        while :; do case $lunlet_frac in *0) lunlet_frac=${lunlet_frac%0} ;; *) break ;; esac; done
        lunlet_text=$lunlet_int${lunlet_frac:+.$lunlet_frac}
    }
    # Positive Unix epoch seconds as lunlet_epoch; a fractional part is dropped.
    lunlet_seconds() {
        lunlet_epoch=${1%%.*}
        case $1 in *.*) case ${1#*.} in *[!0-9]*) return 1 ;; esac ;; esac
        case $lunlet_epoch in ''|*[!0-9]*) return 1 ;; esac
        [ ${#lunlet_epoch} -le 11 ] || return 1
        lunlet_decimal "$lunlet_epoch"; lunlet_epoch=$lunlet_digits
        [ "$lunlet_epoch" -gt 0 ]
    }
    # The used_percentage and resets_at numbers of one reported window, from Claude Code's input as a property list.
    lunlet_fields() {
        lunlet_used= lunlet_resets= lunlet_key= lunlet_depth=0
        lunlet_xml=$(printf '%s' "$lunlet_input" | /usr/bin/plutil -extract "rate_limits.$1" xml1 -o - - 2>/dev/null) || return 1
        lunlet_ifs=$IFS
        IFS='
    '
        for lunlet_element in $lunlet_xml; do
            lunlet_element="<${lunlet_element#*<}"
            case $lunlet_element in
                '<dict>'|'<array>') lunlet_depth=$((lunlet_depth + 1)) lunlet_key= ;;
                '</dict>'|'</array>') lunlet_depth=$((lunlet_depth - 1)) lunlet_key= ;;
                '<key>'*'</key>') lunlet_key=${lunlet_element#<key>} lunlet_key=${lunlet_key%</key>} ;;
                '<integer>'*'</integer>'|'<real>'*'</real>')
                    lunlet_value=${lunlet_element#*>} lunlet_value=${lunlet_value%<*}
                    if [ "$lunlet_depth" -eq 1 ]; then
                        case $lunlet_key in used_percentage) lunlet_used=$lunlet_value ;; resets_at) lunlet_resets=$lunlet_value ;; esac
                    fi
                    lunlet_key= ;;
                *) lunlet_key= ;;
            esac
        done
        IFS=$lunlet_ifs
        [ -n "$lunlet_used" ] && [ -n "$lunlet_resets" ]
    }
    # Merges one input window with its stored "used reset at" value into lunlet_merged; lunlet_fresh is set when the
    # input reported the window. Within one window use never decreases, so a lower value, or one from an earlier window,
    # is an idle session's older response and the stored value stands. $3 is the window length in seconds.
    lunlet_merge() {
        lunlet_fresh= lunlet_merged= lunlet_span=$3 lunlet_stored_scaled=0 lunlet_stored_reset=0
        set -- "$1" $2
        if [ $# -eq 4 ] && lunlet_seconds "$4"; then
            lunlet_stored_at=$lunlet_epoch
            if lunlet_seconds "$3" && lunlet_percent "$2" && [ "$lunlet_epoch" -le $((lunlet_stored_at + lunlet_span + 300)) ]; then
                lunlet_stored_reset=$lunlet_epoch lunlet_stored_scaled=$lunlet_scaled
                lunlet_merged="$lunlet_text $lunlet_epoch $lunlet_stored_at"
            fi
        fi
        lunlet_fields "$1" && lunlet_percent "$lunlet_used" && lunlet_seconds "$lunlet_resets" || return 0
        [ "$lunlet_epoch" -le $((lunlet_now + lunlet_span + 300)) ] || return 0
        lunlet_fresh="$lunlet_text $lunlet_epoch"
        if [ -z "$lunlet_merged" ] || [ "$lunlet_stored_reset" -le "$lunlet_now" ] \
            || [ "$lunlet_epoch" -gt $((lunlet_stored_reset + 300)) ] \
            || { [ $((lunlet_epoch + 300)) -ge "$lunlet_stored_reset" ] && [ "$lunlet_scaled" -ge "$lunlet_stored_scaled" ]; }
        then
            lunlet_merged="$lunlet_fresh $lunlet_now"
        fi
    }
    # A compact time until a reset, such as 1h23m; nothing once it has passed.
    lunlet_countdown() {
        lunlet_left=$(($1 - lunlet_now))
        [ "$lunlet_left" -gt 0 ] || return 1
        lunlet_days=$((lunlet_left / 86400)) lunlet_hours=$((lunlet_left % 86400 / 3600)) lunlet_minutes=$((lunlet_left % 3600 / 60))
        if [ "$lunlet_days" -gt 0 ]; then lunlet_countdown=${lunlet_days}d${lunlet_hours}h
        elif [ "$lunlet_hours" -gt 0 ]; then lunlet_countdown=${lunlet_hours}h${lunlet_minutes}m
        elif [ "$lunlet_minutes" -gt 0 ]; then lunlet_countdown=${lunlet_minutes}m
        else lunlet_countdown='<1m'
        fi
    }
    # Appends "label N%" for a reported window whose reset is still ahead.
    lunlet_show() {
        [ -n "$2" ] || return 1
        set -- "$1" $2
        [ "$3" -gt "$lunlet_now" ] || return 1
        lunlet_line=${lunlet_line:+$lunlet_line · }"$1 ${2%%.*}%"
        [ -n "$lunlet_reset" ] || lunlet_reset=$3
    }

    lunlet_line= lunlet_reset=
    if [ -n "$lunlet_dir" ] && [ -n "$lunlet_now" ] && [ ${#lunlet_input} -le 1048576 ]; then
        lunlet_state=$lunlet_dir/limits lunlet_stored_five= lunlet_stored_week= lunlet_header=
        if [ -f "$lunlet_state" ]; then
            { IFS= read -r lunlet_header
              if [ "$lunlet_header" = "lunlet-claude-limits 1" ]; then
                  while read -r lunlet_name lunlet_values; do
                      case $lunlet_name in
                          five_hour) lunlet_stored_five=$lunlet_values ;;
                          seven_day) lunlet_stored_week=$lunlet_values ;;
                      esac
                  done
              fi
            } < "$lunlet_state" 2>/dev/null
        fi
        lunlet_merge five_hour "$lunlet_stored_five" 18000
        lunlet_five=$lunlet_merged lunlet_five_fresh=$lunlet_fresh
        lunlet_merge seven_day "$lunlet_stored_week" 604800
        lunlet_week=$lunlet_merged lunlet_week_fresh=$lunlet_fresh
        if [ -n "$lunlet_five_fresh$lunlet_week_fresh" ]; then
            lunlet_temporary=$lunlet_dir/.limits.$$
            trap '/bin/rm -f "$lunlet_temporary"; exit 0' HUP INT PIPE TERM
            if { printf 'lunlet-claude-limits 1\n'
                 if [ -n "$lunlet_five" ]; then printf 'five_hour %s\n' "$lunlet_five"; fi
                 if [ -n "$lunlet_week" ]; then printf 'seven_day %s\n' "$lunlet_week"; fi
               } > "$lunlet_temporary" 2>/dev/null && /bin/mv -f "$lunlet_temporary" "$lunlet_state" 2>/dev/null
            then :; else /bin/rm -f "$lunlet_temporary" 2>/dev/null; fi
        fi
        # The weekly log, for the forecast: a reading when the value changes or at least hourly, kept for eight days.
        if [ -n "$lunlet_week_fresh" ] && [ -n "$lunlet_week" ]; then
            lunlet_log=$lunlet_dir/weekly-readings.log
            set -- $lunlet_week
            lunlet_entry="$3 $1 $2" lunlet_value="$1 $2" lunlet_at=$3
            set -- $(/usr/bin/tail -n 1 "$lunlet_log" 2>/dev/null)
            lunlet_append=1
            if [ $# -eq 3 ] && [ "$2 $3" = "$lunlet_value" ]; then
                case $1 in [1-9]*) case $1 in *[!0-9]*) ;; *) [ $((lunlet_at - $1)) -ge 3600 ] || lunlet_append= ;; esac ;; esac
            fi
            if [ -n "$lunlet_append" ] && printf '%s\n' "$lunlet_entry" >> "$lunlet_log" 2>/dev/null; then
                lunlet_cutoff=$((lunlet_now - 691200)) lunlet_first=
                { IFS= read -r lunlet_first; } < "$lunlet_log" 2>/dev/null
                lunlet_first=${lunlet_first%% *}
                case $lunlet_first in [1-9]*) case $lunlet_first in *[!0-9]*) lunlet_first=0 ;; esac ;; *) lunlet_first=0 ;; esac
                if [ "$lunlet_first" -lt "$lunlet_cutoff" ]; then
                    lunlet_temporary=$lunlet_dir/.weekly-readings.$$
                    trap '/bin/rm -f "$lunlet_temporary"; exit 0' HUP INT PIPE TERM
                    if /usr/bin/awk -v cutoff="$lunlet_cutoff" 'NF == 3 && $1 + 0 >= cutoff' "$lunlet_log" 2>/dev/null \
                        | /usr/bin/tail -n 4096 > "$lunlet_temporary" 2>/dev/null \
                        && /bin/mv -f "$lunlet_temporary" "$lunlet_log" 2>/dev/null
                    then :; else /bin/rm -f "$lunlet_temporary" 2>/dev/null; fi
                fi
            fi
        fi
        [ -n "$lunlet_five_fresh" ] && lunlet_show 5h "$lunlet_five"
        [ -n "$lunlet_week_fresh" ] && lunlet_show 7d "$lunlet_week"
        [ -n "$lunlet_reset" ] && lunlet_countdown "$lunlet_reset" && lunlet_line="$lunlet_line · resets $lunlet_countdown"
    fi
    trap 'exit 0' HUP INT PIPE TERM

    # The status line this one replaced, run through /bin/sh with the same input; its output shows only on success.
    if [ -n "$lunlet_dir" ] && lunlet_previous=$(/usr/bin/plutil -extract previousCommand raw -expect string -o - \
        "$lunlet_dir/previous-status-line.json" 2>/dev/null) && [ -n "$lunlet_previous" ]
    then
        if lunlet_output=$(printf '%s' "$lunlet_input" | /bin/sh -c "$lunlet_previous") && [ -n "$lunlet_output" ]; then
            printf '%s\n' "$lunlet_output"
        fi
    fi
    if [ -n "$lunlet_line" ]; then printf '%s\n' "$lunlet_line"; fi
    exit 0
    """# + "\n"
}
