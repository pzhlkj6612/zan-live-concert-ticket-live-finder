#!/bin/bash


set -e
set -o pipefail
set -u
set -x


jq --version >/dev/stderr

offset_second="$1"
homepage_html="$2"

file "${homepage_html}" >/dev/stderr

now_second=$(date '+%s')
limit_second=$((${now_second} + ${offset_second}))


# extract event IDs from homepage

declare -a event_id_list

event_id_list=$(
  grep -oP '/(?:en/)?live/detail/\K[0-9]+' "${homepage_html}" | \
  sort -u
)

echo "event IDs found: ${event_id_list}" >/dev/stderr


# collect live

declare -a live_timestamp_code_row_list
declare -a live_close_timestamp_list

while read -r id; do
  [[ -z "${id}" ]] && continue

  echo "processing [${id}]" >/dev/stderr

  api_response=$(curl -sS \
    -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36 Edg/144.0.0.0' \
    -H 'Accept: application/json' \
    "https://www.zan-live.com/api/live/detail/tickets?id=${id}")

  is_success=$(echo "${api_response}" | jq -r '.isSuccess // false')
  
  if [[ "${is_success}" != "true" ]]; then
    echo -e '\t''API failed, skipped' >/dev/stderr
    continue
  fi

  # Get all valid non-archive tickets with live dates
  # Filter out: null/empty dates, 9999-placeholder dates, and archive streams
  live_entries=$(echo "${api_response}" | jq -c '
    [.result[] | select(
      .liveBeginDate != null and .liveBeginDate != "" and
      (.liveBeginDate | test("^9999") | not) and
      .liveEndDate != null and
      (.liveEndDate | test("^9999") | not) and
      (.isArchiveStream | not)
    )]
  ')

  entry_count=$(echo "${live_entries}" | jq 'length')

  if [[ "${entry_count}" -eq 0 ]]; then
    echo -e '\t''no valid live date, skipped' >/dev/stderr
    continue
  fi

  # Get minimum price from buyable tickets (once per event)
  min_price=$(echo "${api_response}" | jq -r '
    [.result[] | select(.isBuyTicket == true and .buyPrice != null and .buyPrice > 0) | .buyPrice] | min // "N/A"
  ')

  # Format price (once per event)
  if [[ "${min_price}" =~ ^[0-9]+$ ]]; then
    min_price="¥$(printf "%'d" "${min_price}")"
  fi

  # Check if any entry passes the time filter before fetching thumbnail
  has_valid_entry=false
  for i in $(seq 0 $((entry_count - 1))); do
    entry_end=$(echo "${live_entries}" | jq -r ".[$i].liveEndDate // \"\"")
    entry_close_second=$(date -d "${entry_end}" '+%s' 2>/dev/null || echo "0")
    if [[ ${now_second} -le ${entry_close_second} && ${entry_close_second} -le ${limit_second} ]]; then
      has_valid_entry=true
      break
    fi
  done

  if [[ "${has_valid_entry}" != "true" ]]; then
    echo -e '\t''no upcoming entries in range, skipped' >/dev/stderr
    continue
  fi

  # Fetch cover image from event detail page (once per event)
  thumbnail_url=$(curl -sS -L \
    -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36 Edg/144.0.0.0' \
    "https://www.zan-live.com/en/live/detail/${id}" | \
    grep -oP '<meta property="og:image" content="\K[^"]+' || echo '')

  # Process each live entry
  for i in $(seq 0 $((entry_count - 1))); do
    live_info=$(echo "${live_entries}" | jq -c ".[$i]")

    name=$(echo "${live_info}" | jq -r '.liveName // "Unknown"')
    live_begin_date=$(echo "${live_info}" | jq -r '.liveBeginDate')
    live_end_date=$(echo "${live_info}" | jq -r '.liveEndDate // ""')

    # Convert dates (ISO 8601 UTC to JST display)
    if [[ -n "${live_begin_date}" && "${live_begin_date}" != "null" ]]; then
      open_datetime=$(TZ='Asia/Tokyo' date -d "${live_begin_date}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${live_begin_date}")
    else
      open_datetime="TBD"
    fi

    if [[ -n "${live_end_date}" && "${live_end_date}" != "null" ]]; then
      close_datetime=$(TZ='Asia/Tokyo' date -d "${live_end_date}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${live_end_date}")
    else
      close_datetime="TBD"
    fi

    # Convert close date to unix timestamp for filtering/sorting
    close_second=$(date -d "${live_end_date}" '+%s' 2>/dev/null || echo "0")

    if [[ ${now_second} -gt ${close_second} ]]; then
      echo -e '\t'"entry ${i}: already ended, ignored" >/dev/stderr
      continue
    fi

    if [[ ${close_second} -gt ${limit_second} ]]; then
      echo -e '\t'"entry ${i}: too far in the future, ignored" >/dev/stderr
      continue
    fi

    if [[ -n "${thumbnail_url}" ]]; then
      thumbnail_element="<img alt=\"${name}\" src=\"${thumbnail_url}\" height=\"64px\">"
    else
      thumbnail_element='<i>no thumbnail</i>'
    fi

    # Decode HTML entities in name
    name=$(echo "${name}" | sed 's/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g')

    row="$(
      cat <<TABLE_ROW
<tr>
  <td>${open_datetime}</td>
  <td>${close_datetime}</td>
  <td>
    <a href="https://www.zan-live.com/en/live/detail/${id}">${id}</a>
    <br>
    ${thumbnail_element}
    <br>
    ${name}
  </td>
  <td>${min_price}</td>
</tr>
TABLE_ROW
    )"
    live_close_timestamp_list+=("${close_second}")
    live_timestamp_code_row_list+=("${row}")

    echo -e '\t'"entry ${i}: collected" >/dev/stderr
  done

done <<< "${event_id_list}"

echo "count of incoming live = ${#live_timestamp_code_row_list[@]}" >/dev/stderr


# draw table

echo '<table>'

cat <<'TABLE_HEADER'
<thead>
  <th>START (JST)</th>
  <th>END (JST) ↓</th>
  <th>Thumbnail, URL & Title</th>
  <th>Minimal price</th>
</thead>
TABLE_HEADER

if [[ ${#live_timestamp_code_row_list[@]} -gt 0 ]]; then
  sorted_indices=$(
    for i in "${!live_close_timestamp_list[@]}"; do
      echo "${live_close_timestamp_list[$i]} $i"
    done | sort -n | awk '{print $2}'
  )

  for i in ${sorted_indices}; do
    echo "${live_timestamp_code_row_list[$i]}"
  done
fi

echo '</table>'
