#!/bin/bash -e

# $1: message
function debug() {
  $debug && >&2 echo "debug: $1" || return 0
}

# $1: url
function http() {
  local output=$(mktemp)
  local r=$(curl -s -w '%{http_code}' --output $output $1)
  local m=$(<$output)
  rm $output

  [ "$r" -eq "200" ] || { debug "$m"; return 1; } && { echo "$m"; debug "$m"; }
}

readonly maxResults=50
readonly youtubeAPI=https://www.googleapis.com/youtube/v3

# $1: Youtube API key
# $2: Youtube User name
function channels() {
  http "$youtubeAPI/channels?part=contentDetails&key=$1&forUsername=$2"
}

# $1: Youtube API key 
# $2: playlistId
function playlists() {
  http "$youtubeAPI/playlists?key=$1&id=$2&part=snippet"
}

# $1: Youtube API key 
# $2: playlistId
# $3: optional, pageToken
function playlistItems() {
  [ -z "$3" ] && local pageToken= || local pageToken=pageToken=$3
  http "$youtubeAPI/playlistItems?key=$1&playlistId=$2&part=snippet&fields=nextPageToken,items(snippet(resourceId(videoId)))&maxResults=$maxResults&$pageToken"
}

# $1: Youtube API key
# $2: List of comma separated video Id
function videos() {
  http "$youtubeAPI/videos?key=$1&part=contentDetails,id,liveStreamingDetails,localizations,player,recordingDetails,snippet,statistics,status,topicDetails&maxWidth=1280&id=$2"
}

# $1: Youtube API key 
# $2: Youtube playlist id
function get_playlist_videos() {
  local pageToken=""
  local v=""
  while [ "$pageToken" != "null" ]
  do
    local j
    j=$(playlistItems $1 $2 $pageToken) || return $?

    local pageToken
    pageToken=$(jq -r '.nextPageToken' <<< $j) || return $?
    debug "PageToken: $pageToken"

    local videoIds
    videoIds=$(jq -r '[.items[].snippet.resourceId.videoId] | @csv' <<< $j | sed 's/"//g') || return $?
    debug "videoIds: $videoIds"
    v+=$(videos $1 $videoIds) || return $?
  done
  
  j=$(playlists $1 $2) || return $?
  local playlistId
  playlistId=$(jq -r '.items[].snippet.title' <<< $j) || return $?

  jq -sc --arg playlistId "$playlistId" 'map(.items[]) | .[] += { playlistId: $playlistId }' <<< $v
}

# $1: Videos JSON
function get_summary_videos() {
  jq -c '
  [
    .[]
    | 
      { id, playlistId, publishedAt:.snippet.publishedAt, title:.snippet.title, description:.snippet.description, tags:.snippet.tags, thumbnails:.snippet.thumbnails.high.url, duration:.contentDetails.duration
      , embedWidth: .player.embedWidth
      , embedHeight: .player.embedHeight
      , player:(
        "<!DOCTYPE html><html style=\"overflow:hidden\"><head><meta http-equiv=\"X-UA-Compatible\" content=\"IE=edge; IE=11\"/><title>"
        + .snippet.title
        + "</title></head><body><div style=\"position: fixed;left:0; top:0; width: 100%; height: 100%;\">"
        + .player.embedHtml
         | sub("width=\".\\d+\"\\s+height=\".\\d+\""; "width=\"100%\" height=\"100%\"")
         | sub("\"//www"; "\"https://www")
         | sub("src=\"(?<url>[^\\s]+)\""; "src=\"\(.url)?autoplay=1&rel=0&fs=0&modestbranding=1\"")
         | sub("\\s+allow=\".+\"\\s+allowfullscreen"; "")
        + "</div></body></html>"
        )
      }
  ]' <<< $1
}

# $1: Youtube API key 
# $2: Youtube playlist id separated by comma
function get_videos() {
  local i
  local j
  local v=""
  for i in ${2//,/ }
  do
    j=$(get_playlist_videos "$1" "$i") || return $?
    v+=$(get_summary_videos "$j")
  done

  jq -sc '
    add
    | group_by(.id, .publishedAt, .title, .description)
    | map({ 
        id: .[0].id
      , playlistId: map(.playlistId)
      , publishedAt: .[0].publishedAt
      , title: .[0].title
      , description: .[0].description
      , tags: .[0].tags
      , thumbnails: .[0].thumbnails
      , duration: .[0].duration
      , embedWidth: .[0].embedWidth
      , embedHeight: .[0].embedHeight
      , player: .[0].player
      })
    ' <<< "$v"
}

function parse_args() {
  local usage="$(basename "$0") [-h] -k <apiKey> -l playlistId

  where:
      -d  show debug info
      -h  show help
      -k  Youtube API key
      -l  Play List Id
  "

  unset apiKey
  unset userName
  debug=false
  rawOutput=false
  while getopts 'dhk:l:' opt; do
    case "$opt" in
      d) debug=true
         ;;
      h) echo "$usage" && return 0
         ;;
      k) apiKey=$OPTARG
         ;;
      l) playlistIds=$OPTARG
         ;;
      :) printf "missing argument for -%s\n" "$OPTARG" >&2
         echo "$usage" >&2 && exit 1
         ;;
     \?) printf "illegal option: -%s\n" "$OPTARG" >&2
         echo "$usage" >&2 && exit 1
         ;;
    esac
  done
  shift "$((OPTIND - 1))"

  [ -z "$apiKey" ] || [ -z "$playlistIds" ] && echo "$usage" >&2 && exit 1 || return 0
}

parse_args "$@"
get_videos $apiKey $playlistIds