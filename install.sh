#!/data/data/com.termux/files/usr/bin/bash

set -uo pipefail
umask 077

SCRIPT_VERSION="1.3.0"
CODEX_PACKAGE="@mmmbuto/codex-cli-termux@latest"
CLAUDE_PACKAGE="@xurxuo/claude-code-termux@latest"
CLAUDE_NATIVE_PACKAGE="@anthropic-ai/claude-code-linux-arm64@latest"
CODEX_MIN_VERSION="0.147.3"
CLAUDE_MIN_VERSION="2.1.217"
CLAUDE_NATIVE_MIN_VERSION="2.1.227"
NPM_OFFICIAL_REGISTRY="https://registry.npmjs.org/"
NPM_FALLBACK_REGISTRIES=(
  "https://mirrors.cloud.tencent.com/npm/"
  "https://repo.huaweicloud.com/repository/npm/"
  "https://registry.npmmirror.com/"
)
DEEPSEEK_SETUP_URL="https://cdn.deepseek.com/api-docs/codex-deepseek-setup.sh"
DEEPSEEK_MODEL="deepseek-v4-flash"
DEFAULT_CODEX_MODEL="gpt-5.6-sol"
DEFAULT_CLAUDE_MODEL="claude-opus-4-8"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_CYAN=""
fi

if [[ -t 0 ]]; then
  exec 3<&0
elif [[ -t 1 ]]; then
  exec 3</dev/tty
else
  exec 3<&0
fi

info() {
  printf '%s[信息]%s %s\n' "$C_CYAN" "$C_RESET" "$*"
}

ok() {
  printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

warn() {
  printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
}

fail() {
  printf '%s[失败]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

pause() {
  local unused
  printf '\n按回车返回主菜单...'
  IFS= read -r unused <&3 || true
}

ask_yes_no() {
  local prompt=${1:?}
  local default=${2:-y}
  local answer
  local hint="Y/n"

  [[ "$default" == "n" ]] && hint="y/N"
  while true; do
    printf '%s [%s]: ' "$prompt" "$hint"
    IFS= read -r answer <&3 || return 1
    answer=${answer:-$default}
    case "${answer,,}" in
      y|yes|1|是) return 0 ;;
      n|no|0|否) return 1 ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

read_required() {
  local prompt=${1:?}
  local value

  while true; do
    printf '%s: ' "$prompt"
    IFS= read -r value <&3 || return 1
    if [[ -n "$value" ]]; then
      REPLY=$value
      return 0
    fi
    warn "这一项不能为空。"
  done
}

read_secret() {
  local prompt=${1:?}
  local value

  while true; do
    printf '%s: ' "$prompt"
    IFS= read -r -s value <&3 || return 1
    printf '\n'
    if [[ -n "$value" ]]; then
      REPLY=$value
      return 0
    fi
    warn "密钥不能为空。"
  done
}

read_with_default() {
  local prompt=${1:?}
  local default=${2-}
  local value

  printf '%s [%s]: ' "$prompt" "$default"
  IFS= read -r value <&3 || return 1
  REPLY=${value:-$default}
}

is_termux() {
  [[ -n "${PREFIX:-}" && -x "${PREFIX}/bin/pkg" && "${PREFIX}" == *com.termux* ]]
}

preflight() {
  if ! is_termux; then
    fail "本脚本只能在 Termux 内运行。请使用 F-Droid 或 GitHub 版 Termux。"
    return 1
  fi

  case "$(uname -m)" in
    aarch64|arm64) ;;
    *)
      fail "当前架构为 $(uname -m)，这两个适配包只支持 Android ARM64/aarch64。"
      return 1
      ;;
  esac
}

pkg_install() {
  local packages=("$@")
  pkg install -y "${packages[@]}"
}

switch_termux_main_to_ustc() {
  local source_file="$PREFIX/etc/apt/sources.list"
  local tmp_file="${source_file}.tmp.$$"
  local line
  local replaced=0

  if [[ -f "$source_file" ]] && grep -qF 'mirrors.ustc.edu.cn/termux/termux-main' "$source_file"; then
    info "Termux 主仓库已经是中科大镜像。"
    return 0
  fi

  backup_file "$source_file" || return 1
  info "自动切换 Termux 主仓库到中科大镜像..."
  if ! : >"$tmp_file"; then
    fail "无法创建 Termux 临时源配置。"
    return 1
  fi
  if [[ -f "$source_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*deb[[:space:]].*termux-main ]]; then
        if [[ "$replaced" -eq 0 ]]; then
          printf '%s\n' 'deb https://mirrors.ustc.edu.cn/termux/termux-main stable main' >>"$tmp_file"
          replaced=1
        fi
      else
        printf '%s\n' "$line" >>"$tmp_file"
      fi
    done <"$source_file"
  fi
  if [[ "$replaced" -eq 0 ]]; then
    printf '%s\n' 'deb https://mirrors.ustc.edu.cn/termux/termux-main stable main' >>"$tmp_file"
  fi
  if ! chmod 600 "$tmp_file" \
    || ! mv -f "$tmp_file" "$source_file"; then
    rm -f "$tmp_file"
    fail "Termux 主仓库切换失败。"
    return 1
  fi
}

switch_glibc_to_direct_source() {
  local source_file="$PREFIX/etc/apt/sources.list.d/glibc.list"
  local tmp_file="${source_file}.tmp.$$"

  if [[ -f "$source_file" ]] && grep -qF 'https://packages.termux.dev/apt/termux-glibc/' "$source_file" \
    && ! grep -qE '^[[:space:]]*deb[[:space:]]+https://packages-cf\.termux\.dev' "$source_file"; then
    info "glibc 仓库已经使用非 Cloudflare 官方源。"
    return 0
  fi

  mkdir -p "$(dirname "$source_file")" || return 1
  backup_file "$source_file" || return 1
  info "自动切换 glibc 仓库到非 Cloudflare 官方源..."
  if ! printf '%s\n' 'deb https://packages.termux.dev/apt/termux-glibc/ glibc stable' >"$tmp_file" \
    || ! chmod 600 "$tmp_file" \
    || ! mv -f "$tmp_file" "$source_file"; then
    rm -f "$tmp_file"
    fail "glibc 仓库切换失败。"
    return 1
  fi
}

version_at_least() {
  local candidate=${1:?}
  local minimum=${2:?}
  local lowest

  lowest=$(printf '%s\n%s\n' "$minimum" "$candidate" | sort -V | head -n 1)
  [[ "$lowest" == "$minimum" ]]
}

npm_registry_version() {
  local package=${1:?}
  local registry=${2:?}

  timeout 20 npm view "$package" version --registry="$registry" --silent 2>/dev/null | tail -n 1
}

npm_install_with_fallback() {
  local package=${1:?}
  local minimum=${2:?}
  local label=${3:?}
  local original_registry expected_version candidate_version registry
  local npmrc_backed_up=0

  original_registry=$(npm config get registry 2>/dev/null || printf '%s' "$NPM_OFFICIAL_REGISTRY")
  expected_version=$(npm_registry_version "$package" "$NPM_OFFICIAL_REGISTRY" || true)

  if npm install -g --force "$package" --registry="$NPM_OFFICIAL_REGISTRY"; then
    return 0
  fi

  warn "$label 从官方 npm 安装失败，开始尝试国内镜像。"
  for registry in "${NPM_FALLBACK_REGISTRIES[@]}"; do
    info "检查 npm 镜像：$registry"
    candidate_version=$(npm_registry_version "$package" "$registry" || true)
    if [[ -z "$candidate_version" ]]; then
      warn "该镜像没有返回 $label 的可用版本，跳过。"
      continue
    fi
    if ! version_at_least "$candidate_version" "$minimum"; then
      warn "该镜像版本 $candidate_version 低于最低要求 $minimum，跳过以防降级。"
      continue
    fi
    if [[ -n "$expected_version" && "$candidate_version" != "$expected_version" ]]; then
      warn "该镜像版本 $candidate_version 落后于官方 $expected_version，跳过。"
      continue
    fi

    if [[ "$npmrc_backed_up" -eq 0 ]]; then
      backup_file "$HOME/.npmrc" || return 1
      npmrc_backed_up=1
    fi
    info "切换 npm 源并重试：$registry"
    if ! npm config set registry "$registry"; then
      warn "无法切换到该 npm 镜像。"
      continue
    fi
    if npm install -g --force "$package" --registry="$registry"; then
      ok "$label 已通过国内镜像安装，当前 npm 源保留为 $registry"
      return 0
    fi
  done

  npm config set registry "$original_registry" >/dev/null 2>&1 || true
  fail "$label 在原 npm 源及国内镜像上均安装失败。"
  return 1
}

ensure_common_dependencies() {
  info "刷新 Termux 软件源索引..."
  if ! pkg update -y; then
    warn "当前 Termux 软件源刷新失败，准备自动切换中科大镜像。"
    switch_termux_main_to_ustc || return 1
    if ! pkg update -y; then
      fail "切换中科大镜像后仍无法刷新软件源，请检查网络。"
      return 1
    fi
  fi

  info "补齐 Node.js、Git、curl、jq、ripgrep、证书等基础依赖..."
  if ! pkg_install nodejs-lts git curl jq ripgrep openssh ca-certificates; then
    warn "基础依赖下载失败，自动切换中科大镜像后重试。"
    switch_termux_main_to_ustc || return 1
    pkg update -y || return 1
    if ! pkg_install nodejs-lts git curl jq ripgrep openssh ca-certificates; then
      fail "切源后基础依赖仍安装失败，请检查网络。"
      return 1
    fi
  fi

  hash -r
  command -v node >/dev/null 2>&1 || { fail "Node.js 安装后仍不可用。"; return 1; }
  command -v npm >/dev/null 2>&1 || { fail "npm 安装后仍不可用。"; return 1; }
}

ensure_claude_dependencies() {
  info "补齐 Claude Code 所需的 glibc 运行环境..."
  if ! pkg_install glibc-repo; then
    fail "glibc-repo 安装失败。"
    return 1
  fi
  if ! pkg update -y; then
    warn "glibc 仓库刷新失败，自动切换非 Cloudflare 官方源。"
    switch_glibc_to_direct_source || return 1
    pkg update -y || return 1
  fi
  if ! pkg_install glibc-runner; then
    warn "glibc-runner 下载失败，切换 glibc 仓库后重试。"
    switch_glibc_to_direct_source || return 1
    pkg update -y || return 1
    if ! pkg_install glibc-runner; then
      fail "切源后 glibc-runner 仍安装失败。"
      return 1
    fi
  fi
}

backup_file() {
  local file=${1:?}
  local backup="${file}.Bak"

  [[ -f "$file" ]] || return 0
  if cp -fp -- "$file" "$backup"; then
    chmod 600 "$backup" 2>/dev/null || true
    info "旧配置已备份到 $backup（下次备份会覆盖此文件）"
  else
    fail "无法备份 $file"
    return 1
  fi
}

valid_url() {
  [[ "$1" =~ ^https?://[^/[:space:]]+(/[^[:space:]]*)?$ ]]
}

normalize_url() {
  local url=${1:?}
  while [[ "$url" == */ ]]; do
    url=${url%/}
  done
  REPLY=$url
}

current_codex_model() {
  local config="$HOME/.codex/config.toml"
  local model

  if [[ -f "$config" ]]; then
    model=$(sed -nE 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$config" | head -n 1)
  fi
  printf '%s' "${model:-$DEFAULT_CODEX_MODEL}"
}

current_claude_model() {
  local settings="$HOME/.claude/settings.json"
  local model

  if [[ -f "$settings" ]] && command -v jq >/dev/null 2>&1; then
    model=$(jq -r '.model // empty' "$settings" 2>/dev/null || true)
  fi
  printf '%s' "${model:-$DEFAULT_CLAUDE_MODEL}"
}

codex_active_provider() {
  local config="$HOME/.codex/config.toml"

  [[ -f "$config" ]] || return 1
  sed -nE 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$config" | head -n 1
}

save_current_relay_snapshot() {
  local codex_dir="$HOME/.codex"
  local config="$codex_dir/config.toml"
  local auth="$codex_dir/auth.json"
  local provider

  provider=$(codex_active_provider || true)
  [[ "$provider" == "my_codex" && -f "$config" && -f "$auth" ]] || return 1
  if ! cp -fp -- "$config" "$codex_dir/config.toml.Relay" \
    || ! cp -fp -- "$auth" "$codex_dir/auth.json.Relay"; then
    fail "保存中转配置快照失败。"
    return 1
  fi
  chmod 600 "$codex_dir/config.toml.Relay" "$codex_dir/auth.json.Relay"
  info "中转配置快照已保存，可从主菜单一键恢复。"
}

write_codex_config() {
  local endpoint=${1:?}
  local api_key=${2:?}
  local model=${3:?}
  local codex_dir="$HOME/.codex"
  local config="$codex_dir/config.toml"
  local auth="$codex_dir/auth.json"
  local tmp_dir tmp_config tmp_auth endpoint_toml model_toml home_toml

  mkdir -p "$codex_dir"
  chmod 700 "$codex_dir"
  backup_file "$config" || return 1
  backup_file "$auth" || return 1

  tmp_dir=$(mktemp -d "$codex_dir/.termux-agent.XXXXXX") || return 1
  tmp_config="$tmp_dir/config.toml"
  tmp_auth="$tmp_dir/auth.json"

  endpoint_toml=$(printf '%s' "$endpoint" | jq -Rs .)
  model_toml=$(printf '%s' "$model" | jq -Rs .)
  home_toml=$(printf '%s' "$HOME" | jq -Rs .)

  if ! {
    printf 'model_provider = "my_codex"\n'
    printf 'model = %s\n' "$model_toml"
    printf 'model_reasoning_effort = "xhigh"\n'
    printf 'disable_response_storage = true\n'
    printf 'approvals_reviewer = "user"\n\n'
    printf 'approval_policy = "never"\n'
    printf 'sandbox_mode = "danger-full-access"\n'
    printf 'service_tier = "fast"\n\n'
    printf '[model_providers.my_codex]\n'
    printf 'name = "my_codex"\n'
    printf 'base_url = %s\n' "$endpoint_toml"
    printf 'wire_api = "responses"\n'
    printf 'requires_openai_auth = true\n\n'
    printf '[notice]\n'
    printf 'hide_full_access_warning = true\n\n'
    printf '[projects.%s]\n' "$home_toml"
    printf 'trust_level = "trusted"\n'
  } >"$tmp_config"; then
    rm -rf "$tmp_dir"
    fail "Codex 配置模板生成失败。"
    return 1
  fi

  printf '%s' "$api_key" >"$tmp_dir/key"
  if ! jq -n --rawfile key "$tmp_dir/key" '{auth_mode:"apikey", OPENAI_API_KEY:$key}' >"$tmp_auth"; then
    rm -rf "$tmp_dir"
    fail "Codex 认证文件生成失败。"
    return 1
  fi

  if ! chmod 600 "$tmp_config" "$tmp_auth" \
    || ! mv -f "$tmp_config" "$config" \
    || ! mv -f "$tmp_auth" "$auth"; then
    rm -rf "$tmp_dir"
    fail "Codex 配置写入失败，旧配置备份仍然保留。"
    return 1
  fi
  rm -rf "$tmp_dir"

  save_current_relay_snapshot || return 1

  ok "Codex 中转配置已写入。"
  info "端点：$endpoint"
  info "模型：$model"
}

configure_codex() {
  local endpoint api_key model default_model

  command -v jq >/dev/null 2>&1 || {
    ensure_common_dependencies || return 1
  }

  while true; do
    read_required "请输入 Codex 中转端点（通常以 /v1 结尾）" || return 1
    endpoint=$REPLY
    if valid_url "$endpoint"; then
      normalize_url "$endpoint"
      endpoint=$REPLY
      break
    fi
    warn "端点必须以 http:// 或 https:// 开头，且不能包含空格。"
  done

  read_secret "请输入 Codex API 密钥（输入内容不会显示）" || return 1
  api_key=$REPLY
  default_model=$(current_codex_model)
  read_with_default "请输入 Codex 模型名" "$default_model" || return 1
  model=$REPLY

  write_codex_config "$endpoint" "$api_key" "$model"
  unset api_key REPLY
}

prepare_chatgpt_official() {
  local codex_dir="$HOME/.codex"
  local config="$codex_dir/config.toml"
  local auth="$codex_dir/auth.json"
  local tmp_dir tmp_config home_toml

  command -v jq >/dev/null 2>&1 || {
    ensure_common_dependencies || return 1
  }
  mkdir -p "$codex_dir" || return 1
  chmod 700 "$codex_dir" || return 1
  save_current_relay_snapshot || true
  backup_file "$config" || return 1
  backup_file "$auth" || return 1

  tmp_dir=$(mktemp -d "$codex_dir/.official.XXXXXX") || return 1
  tmp_config="$tmp_dir/config.toml"
  home_toml=$(printf '%s' "$HOME" | jq -Rs .) || { rm -rf "$tmp_dir"; return 1; }
  {
    printf 'approval_policy = "never"\n'
    printf 'sandbox_mode = "danger-full-access"\n\n'
    printf '[notice]\n'
    printf 'hide_full_access_warning = true\n\n'
    printf '[projects.%s]\n' "$home_toml"
    printf 'trust_level = "trusted"\n'
  } >"$tmp_config"
  chmod 600 "$tmp_config"
  if ! mv -f "$tmp_config" "$config"; then
    rm -rf "$tmp_dir"
    fail "官方登录配置写入失败。"
    return 1
  fi
  rm -rf "$tmp_dir"

  if [[ -f "$auth" ]]; then
    mv -f "$auth" "$codex_dir/auth.json.BeforeOfficial" || return 1
    chmod 600 "$codex_dir/auth.json.BeforeOfficial"
  fi
  ok "已切换到 ChatGPT 官方登录模式。"
}

use_chatgpt_official() {
  prepare_chatgpt_official || return 1
  info "即将直接进入 Codex；国内网络问题请自行处理。"
  codex
}

download_deepseek_setup() {
  local output=${1:?}

  info "下载 DeepSeek 官方 Codex 配置器..."
  if ! curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --retry 2 \
    --connect-timeout 10 \
    --max-time 90 \
    --output "$output" \
    "$DEEPSEEK_SETUP_URL"; then
    fail "DeepSeek 官方配置器下载失败，请检查网络后重试。"
    return 1
  fi
  if ! bash -n "$output"; then
    fail "DeepSeek 官方配置器语法校验失败，已停止执行。"
    return 1
  fi
  chmod 700 "$output"
}

cleanup_stale_deepseek_state() {
  local codex_dir="$HOME/.codex"
  local models="$codex_dir/models.json"
  local backup_dir="$codex_dir/backup-deepseek"

  if [[ -f "$models" ]]; then
    backup_file "$models" || return 1
    rm -f "$models"
  fi
  if [[ -d "$backup_dir" ]]; then
    info "清理上一轮 DeepSeek 配置器状态，当前配置已经单独备份。"
    rm -rf "$backup_dir"
  fi
}

update_existing_deepseek_key() {
  local api_key=${1:?}
  local config="$HOME/.codex/config.toml"
  local tmp_config="${config}.deepseek-key.$$"

  backup_file "$config" || return 1
  if ! sed -E \
    "s#^[[:space:]]*experimental_bearer_token[[:space:]]*=.*#experimental_bearer_token = \"$api_key\"#" \
    "$config" >"$tmp_config"; then
    rm -f "$tmp_config"
    return 1
  fi
  if ! rg -q '^experimental_bearer_token = "sk-' "$tmp_config"; then
    rm -f "$tmp_config"
    fail "没有找到 DeepSeek 密钥字段，无法更新。"
    return 1
  fi
  chmod 600 "$tmp_config"
  mv -f "$tmp_config" "$config"
}

configure_deepseek_codex() {
  local codex_dir="$HOME/.codex"
  local provider api_key tmp_dir setup_file

  command -v codex >/dev/null 2>&1 || {
    fail "尚未安装 Codex，请先使用主菜单 1 安装。"
    return 1
  }
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    ensure_common_dependencies || return 1
  fi
  mkdir -p "$codex_dir" || return 1
  chmod 700 "$codex_dir"

  printf '%s\n' '请先前往 DeepSeek 开放平台申请 API Key：'
  printf '%s\n' 'https://platform.deepseek.com/api_keys'
  printf '%s\n' "当前官方支持的 Codex 模型：$DEEPSEEK_MODEL"
  while true; do
    read_secret "请输入 DeepSeek API Key（以 sk- 开头）" || return 1
    api_key=$REPLY
    if [[ "$api_key" =~ ^sk-[A-Za-z0-9_-]+$ ]]; then
      break
    fi
    warn "DeepSeek API Key 格式不正确，应以 sk- 开头且只包含字母、数字、下划线或横线。"
  done

  provider=$(codex_active_provider || true)
  if [[ "$provider" == "deepseek" && -f "$codex_dir/models.json" ]]; then
    update_existing_deepseek_key "$api_key" || return 1
    ok "DeepSeek API Key 已更新，当前模型仍为 $DEEPSEEK_MODEL。"
    unset api_key REPLY
    return 0
  fi

  save_current_relay_snapshot || true
  backup_file "$codex_dir/config.toml" || return 1
  backup_file "$codex_dir/auth.json" || return 1
  cleanup_stale_deepseek_state || return 1

  tmp_dir=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/deepseek-codex.XXXXXX") || return 1
  setup_file="$tmp_dir/setup.sh"
  if ! download_deepseek_setup "$setup_file"; then
    rm -rf "$tmp_dir"
    return 1
  fi
  if ! printf '1\n' | DEEPSEEK_API_KEY="$api_key" bash "$setup_file"; then
    rm -rf "$tmp_dir"
    fail "DeepSeek 官方配置器执行失败，原配置备份仍然保留。"
    return 1
  fi
  rm -rf "$tmp_dir"

  provider=$(codex_active_provider || true)
  if [[ "$provider" != "deepseek" ]] \
    || ! rg -q '"slug"[[:space:]]*:[[:space:]]*"deepseek-v4-flash"' "$codex_dir/models.json"; then
    fail "DeepSeek 配置结果校验失败。"
    return 1
  fi
  chmod 600 "$codex_dir/config.toml" "$codex_dir/models.json"
  ok "Codex 已切换到 $DEEPSEEK_MODEL（小白推荐）。"
  warn "目前不要选择 deepseek-v4-pro，DeepSeek 官方文档标注其暂未开放 Codex 接入。"
  info "需要切回原中转站时，使用主菜单的“恢复 Codex 中转配置”。"
  unset api_key REPLY
}

restore_codex_relay() {
  local codex_dir="$HOME/.codex"
  local config="$codex_dir/config.toml"
  local auth="$codex_dir/auth.json"
  local relay_config="$codex_dir/config.toml.Relay"
  local relay_auth="$codex_dir/auth.json.Relay"
  local official_backup="$codex_dir/backup-deepseek/config.toml"

  if [[ ! -f "$relay_config" && -f "$official_backup" ]]; then
    relay_config=$official_backup
  fi
  if [[ ! -f "$relay_config" || ! -f "$relay_auth" ]]; then
    fail "没有找到完整的中转配置快照。请使用主菜单 3 重新填写中转端点和密钥。"
    return 1
  fi

  backup_file "$config" || return 1
  backup_file "$auth" || return 1
  if ! cp -fp -- "$relay_config" "$config" \
    || ! cp -fp -- "$relay_auth" "$auth"; then
    fail "中转配置恢复失败。"
    return 1
  fi
  chmod 600 "$config" "$auth"
  if [[ -f "$codex_dir/models.json" ]]; then
    backup_file "$codex_dir/models.json" || return 1
    rm -f "$codex_dir/models.json"
  fi
  if [[ -d "$codex_dir/backup-deepseek" ]]; then
    rm -rf "$codex_dir/backup-deepseek"
  fi
  ok "Codex 中转配置已恢复。"
  info "DeepSeek 会话没有删除；Codex 会按登录方式分别显示历史会话。"
}

codex_access_menu() {
  local choice

  printf '\n%sCodex 使用方式%s\n' "$C_BOLD" "$C_RESET"
  printf '  1. 使用 ChatGPT 官方登录（网络问题自行解决，直接进入 Codex）\n'
  printf '  2. 使用中转站\n'
  printf '  3. 接入 DeepSeek（前往开放平台申请 Key，小白推荐）\n'
  printf '  0. 暂不配置\n'
  printf '请选择 [0-3]: '
  IFS= read -r choice <&3 || return 1
  case "$choice" in
    1) use_chatgpt_official ;;
    2) configure_codex ;;
    3) configure_deepseek_codex ;;
    0) info "已跳过 Codex 登录与服务商配置。" ;;
    *) warn "无效选项。"; return 1 ;;
  esac
}

write_claude_config() {
  local endpoint=${1:?}
  local api_key=${2:?}
  local model=${3:?}
  local claude_dir="$HOME/.claude"
  local settings="$claude_dir/settings.json"
  local tmp_dir tmp_settings source_settings

  mkdir -p "$claude_dir"
  chmod 700 "$claude_dir"
  backup_file "$settings" || return 1

  tmp_dir=$(mktemp -d "$claude_dir/.termux-agent.XXXXXX") || return 1
  tmp_settings="$tmp_dir/settings.json"
  source_settings="$tmp_dir/source.json"
  if [[ -f "$settings" ]] && jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    if ! cp "$settings" "$source_settings"; then
      rm -rf "$tmp_dir"
      fail "无法读取现有 Claude 配置。"
      return 1
    fi
  else
    printf '{}\n' >"$source_settings"
  fi

  printf '%s' "$endpoint" >"$tmp_dir/endpoint"
  printf '%s' "$api_key" >"$tmp_dir/key"
  printf '%s' "$model" >"$tmp_dir/model"
  if ! jq \
    --rawfile endpoint "$tmp_dir/endpoint" \
    --rawfile key "$tmp_dir/key" \
    --rawfile model "$tmp_dir/model" \
    '.env = (.env // {})
     | .env.ANTHROPIC_BASE_URL = $endpoint
     | .env.ANTHROPIC_API_KEY = $key
     | del(.env.ANTHROPIC_AUTH_TOKEN)
     | .env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"
     | .permissions = (.permissions // {})
     | .permissions.defaultMode = "bypassPermissions"
     | .model = $model
     | .effortLevel = "xhigh"
     | .skipDangerousModePermissionPrompt = true' \
    "$source_settings" >"$tmp_settings"; then
    rm -rf "$tmp_dir"
    fail "Claude 配置生成失败。"
    return 1
  fi

  if ! jq -e . "$tmp_settings" >/dev/null 2>&1; then
    rm -rf "$tmp_dir"
    fail "Claude 配置生成失败。"
    return 1
  fi

  if ! chmod 600 "$tmp_settings" || ! mv -f "$tmp_settings" "$settings"; then
    rm -rf "$tmp_dir"
    fail "Claude 配置写入失败，旧配置备份仍然保留。"
    return 1
  fi
  rm -rf "$tmp_dir"

  ok "Claude Code 中转配置已写入。"
  info "端点：$endpoint"
  info "模型：$model"
}

configure_claude() {
  local endpoint api_key model default_model

  command -v jq >/dev/null 2>&1 || {
    ensure_common_dependencies || return 1
  }

  while true; do
    read_required "请输入 Claude 中转端点" || return 1
    endpoint=$REPLY
    if valid_url "$endpoint"; then
      normalize_url "$endpoint"
      endpoint=$REPLY
      break
    fi
    warn "端点必须以 http:// 或 https:// 开头，且不能包含空格。"
  done

  read_secret "请输入 Claude API 密钥（输入内容不会显示）" || return 1
  api_key=$REPLY
  default_model=$(current_claude_model)
  read_with_default "请输入 Claude 模型名" "$default_model" || return 1
  model=$REPLY

  write_claude_config "$endpoint" "$api_key" "$model"
  unset api_key REPLY
}

codex_saved_endpoint() {
  local config="$HOME/.codex/config.toml"

  [[ -f "$config" ]] || return 1
  sed -nE 's/^[[:space:]]*base_url[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$config" | head -n 1
}

codex_saved_key() {
  local auth="$HOME/.codex/auth.json"

  [[ -f "$auth" ]] || return 1
  jq -r '.OPENAI_API_KEY // empty' "$auth" 2>/dev/null
}

build_models_urls() {
  local endpoint=${1:?}
  local base

  normalize_url "$endpoint"
  base=$REPLY
  case "$base" in
    */models)
      MODELS_PRIMARY_URL=$base
      MODELS_ALTERNATE_URL=""
      ;;
    */chat/completions)
      MODELS_PRIMARY_URL="${base%/chat/completions}/models"
      MODELS_ALTERNATE_URL=""
      ;;
    */responses)
      MODELS_PRIMARY_URL="${base%/responses}/models"
      MODELS_ALTERNATE_URL=""
      ;;
    */v1)
      MODELS_PRIMARY_URL="$base/models"
      MODELS_ALTERNATE_URL=""
      ;;
    *)
      MODELS_PRIMARY_URL="$base/models"
      MODELS_ALTERNATE_URL="$base/v1/models"
      ;;
  esac
}

request_openai_models() {
  local url=${1:?}
  local api_key=${2:?}
  local work_dir=${3:?}
  local header_file="$work_dir/headers"
  local response_file="$work_dir/response.json"
  local error_file="$work_dir/curl.error"

  {
    printf 'Authorization: Bearer %s\n' "$api_key"
    printf 'Accept: application/json\n'
  } >"$header_file"
  chmod 600 "$header_file"
  : >"$response_file"
  : >"$error_file"

  OPENAI_HTTP_STATUS=$(curl \
    --silent \
    --show-error \
    --proto '=http,https' \
    --connect-timeout 10 \
    --max-time 30 \
    --output "$response_file" \
    --write-out '%{http_code}' \
    --header "@$header_file" \
    "$url" 2>"$error_file")
  OPENAI_CURL_EXIT=$?
  rm -f "$header_file"
}

openai_error_message() {
  local response_file=${1:?}
  local message=""

  if [[ -s "$response_file" ]] && jq -e . "$response_file" >/dev/null 2>&1; then
    message=$(jq -r '.error.message // .message // empty' "$response_file" 2>/dev/null || true)
  elif [[ -s "$response_file" ]]; then
    message=$(dd if="$response_file" bs=500 count=1 2>/dev/null | tr '\r\n' ' ')
  fi
  printf '%s' "${message:-接口未返回详细错误信息}"
}

print_openai_models() {
  local response_file=${1:?}
  local models model
  local count=0

  if ! jq -e 'type == "object" and (.data | type == "array")' "$response_file" >/dev/null 2>&1; then
    warn "HTTP 请求成功，但响应不是 OpenAI 模型列表格式。"
    return 1
  fi

  models=$(jq -r '.data[]? | .id // empty' "$response_file" 2>/dev/null | sort -u)
  if [[ -z "$models" ]]; then
    warn "连接和鉴权成功，但模型列表为空。"
    return 0
  fi

  printf '\n%s可用模型%s\n' "$C_BOLD" "$C_RESET"
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    count=$((count + 1))
    printf '  %3d. %s\n' "$count" "$model"
  done <<<"$models"
  printf '\n共获取到 %d 个模型。\n' "$count"
}

test_openai_relay() {
  local choice endpoint api_key work_dir url error_message provider
  local saved_endpoint=""
  local saved_key=""
  local -a urls=()

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    ensure_common_dependencies || return 1
  fi

  printf '%sOpenAI 格式中转测试%s\n' "$C_BOLD" "$C_RESET"
  printf '  1. 使用当前 Codex 配置\n'
  printf '  2. 临时输入端点和密钥\n'
  printf '  0. 返回主菜单\n'
  printf '请选择 [0-2]: '
  IFS= read -r choice <&3 || return 1

  case "$choice" in
    1)
      provider=$(codex_active_provider || true)
      if [[ "$provider" != "my_codex" ]]; then
        fail "当前 Codex 不是中转站模式，请先恢复中转配置，或选择临时输入。"
        return 1
      fi
      saved_endpoint=$(codex_saved_endpoint || true)
      saved_key=$(codex_saved_key || true)
      if [[ -z "$saved_endpoint" || -z "$saved_key" ]]; then
        fail "当前 Codex 端点或密钥不存在，请先使用菜单 3 配置。"
        return 1
      fi
      endpoint=$saved_endpoint
      api_key=$saved_key
      ;;
    2)
      while true; do
        read_required "请输入 OpenAI 兼容端点（建议以 /v1 结尾）" || return 1
        endpoint=$REPLY
        if valid_url "$endpoint"; then
          break
        fi
        warn "端点必须以 http:// 或 https:// 开头，且不能包含空格。"
      done
      read_secret "请输入 API 密钥（输入内容不会显示）" || return 1
      api_key=$REPLY
      ;;
    0) return 0 ;;
    *)
      warn "无效选项。"
      return 1
      ;;
  esac

  build_models_urls "$endpoint"
  urls+=("$MODELS_PRIMARY_URL")
  [[ -z "$MODELS_ALTERNATE_URL" ]] || urls+=("$MODELS_ALTERNATE_URL")
  work_dir=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/termux-openai-test.XXXXXX") || return 1

  for url in "${urls[@]}"; do
    info "正在测试：$url"
    request_openai_models "$url" "$api_key" "$work_dir"

    if [[ "$OPENAI_CURL_EXIT" -eq 0 && "$OPENAI_HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
      ok "中转连接和 Bearer 鉴权成功，HTTP $OPENAI_HTTP_STATUS"
      if print_openai_models "$work_dir/response.json"; then
        rm -rf "$work_dir"
        unset api_key saved_key REPLY
        return 0
      fi
    fi

    if [[ "$OPENAI_CURL_EXIT" -ne 0 ]]; then
      error_message=$(dd if="$work_dir/curl.error" bs=500 count=1 2>/dev/null | tr '\r\n' ' ')
      warn "连接失败：${error_message:-curl 错误 $OPENAI_CURL_EXIT}"
    else
      error_message=$(openai_error_message "$work_dir/response.json")
      warn "接口返回 HTTP $OPENAI_HTTP_STATUS：$error_message"
    fi
  done

  rm -rf "$work_dir"
  unset api_key saved_key REPLY
  fail "未能获取 OpenAI 模型列表。请检查端点、密钥权限或中转站的 /models 接口。"
  return 1
}

show_codex_tips() {
  printf '\n%sCodex 常用命令%s\n' "$C_BOLD" "$C_RESET"
  printf '  %-24s %s\n' 'codex' '启动 Codex'
  printf '  %-24s %s\n' 'codex resume' '打开历史对话选择器'
  printf '  %-24s %s\n' 'codex resume --last' '恢复最近一次对话'
  printf '  %-24s %s\n' 'codex doctor' '检查安装和配置'
  printf '  %-24s %s\n' '/model' '在对话内选择模型'
  printf '  %-24s %s\n' '/resume' '在对话内恢复历史对话'
  printf '  %-24s %s\n' '/status' '查看当前模型、权限和用量状态'
}

show_claude_tips() {
  printf '\n%sClaude Code 常用命令%s\n' "$C_BOLD" "$C_RESET"
  printf '  %-24s %s\n' 'claude' '启动 Claude Code'
  printf '  %-24s %s\n' 'claude --resume' '打开历史对话选择器'
  printf '  %-24s %s\n' 'claude --continue' '恢复当前目录最近一次对话'
  printf '  %-24s %s\n' 'claude doctor' '检查安装和配置'
  printf '  %-24s %s\n' '/model' '在对话内选择模型'
  printf '  %-24s %s\n' '/resume' '在对话内恢复历史对话'
  printf '  %-24s %s\n' '/compact' '压缩长对话，腾出上下文'
  printf '  %-24s %s\n' '/help' '查看全部命令'
}

install_codex() {
  preflight || return 1
  ensure_common_dependencies || return 1

  info "安装或更新 Termux 专用 Codex：$CODEX_PACKAGE"
  npm_install_with_fallback "$CODEX_PACKAGE" "$CODEX_MIN_VERSION" "Codex" || return 1
  hash -r

  if ! command -v codex >/dev/null 2>&1; then
    fail "安装完成但找不到 codex 命令。"
    return 1
  fi
  ok "$(codex --version 2>/dev/null || printf 'Codex 已安装')"

  codex_access_menu || return 1
  show_codex_tips
}

install_claude() {
  preflight || return 1
  ensure_common_dependencies || return 1
  ensure_claude_dependencies || return 1

  info "安装或更新 Termux 专用 Claude Code：$CLAUDE_PACKAGE"
  npm_install_with_fallback "$CLAUDE_PACKAGE" "$CLAUDE_MIN_VERSION" "Claude Code Termux 包" || return 1

  info "安装或修复 Claude Code ARM64 原生组件..."
  npm_install_with_fallback "$CLAUDE_NATIVE_PACKAGE" "$CLAUDE_NATIVE_MIN_VERSION" "Claude Code ARM64 原生组件" || return 1
  hash -r

  if ! command -v claude >/dev/null 2>&1; then
    fail "安装完成但找不到 claude 命令。"
    return 1
  fi
  ok "$(CLAUDE_CODE_TERMUX_NO_AUTO_UPDATE=1 timeout 20 claude --version 2>/dev/null || printf 'Claude Code 已安装')"

  if ask_yes_no "是否现在配置 Claude Code 中转站" y; then
    configure_claude || return 1
  else
    info "已跳过中转配置。使用官方账号时可运行：claude auth login"
  fi
  show_claude_tips
}

diagnose() {
  local value provider active_model

  printf '\n%s环境诊断%s\n' "$C_BOLD" "$C_RESET"
  printf '  脚本版本：%s\n' "$SCRIPT_VERSION"
  printf '  系统架构：%s\n' "$(uname -m)"
  printf '  Termux PREFIX：%s\n' "${PREFIX:-未检测到}"

  for command_name in node npm git curl jq rg grun codex claude; do
    if command -v "$command_name" >/dev/null 2>&1; then
      printf '  %s%-8s%s %s\n' "$C_GREEN" "$command_name" "$C_RESET" "$(command -v "$command_name")"
    else
      printf '  %s%-8s%s 未安装\n' "$C_RED" "$command_name" "$C_RESET"
    fi
  done

  if command -v codex >/dev/null 2>&1; then
    value=$(codex --version 2>/dev/null || true)
    printf '  Codex 版本：%s\n' "${value:-无法读取}"
  fi
  if command -v claude >/dev/null 2>&1; then
    value=$(CLAUDE_CODE_TERMUX_NO_AUTO_UPDATE=1 timeout 20 claude --version 2>/dev/null || true)
    printf '  Claude 版本：%s\n' "${value:-无法读取}"
  fi

  provider=$(codex_active_provider || true)
  active_model=$(current_codex_model)
  case "$provider" in
    my_codex)
      if [[ -f "$HOME/.codex/auth.json" ]] \
        && jq -e '.OPENAI_API_KEY | type == "string" and length > 0' "$HOME/.codex/auth.json" >/dev/null 2>&1; then
        printf '  Codex 模式：%s中转站%s（%s）\n' "$C_GREEN" "$C_RESET" "$active_model"
      else
        printf '  Codex 模式：%s中转配置不完整%s\n' "$C_YELLOW" "$C_RESET"
      fi
      ;;
    deepseek)
      printf '  Codex 模式：%sDeepSeek%s（%s）\n' "$C_GREEN" "$C_RESET" "$active_model"
      ;;
    *)
      if [[ -f "$HOME/.codex/config.toml" ]]; then
        printf '  Codex 模式：ChatGPT 官方登录\n'
      else
        printf '  Codex 配置：未创建\n'
      fi
      ;;
  esac

  if [[ -f "$HOME/.claude/settings.json" ]]; then
    if jq -e '.env.ANTHROPIC_BASE_URL | type == "string" and length > 0' "$HOME/.claude/settings.json" >/dev/null 2>&1 \
      && jq -e '.env.ANTHROPIC_API_KEY | type == "string" and length > 0' "$HOME/.claude/settings.json" >/dev/null 2>&1; then
      printf '  Claude 配置：%s端点和密钥已设置%s\n' "$C_GREEN" "$C_RESET"
    else
      printf '  Claude 配置：%s不完整%s\n' "$C_YELLOW" "$C_RESET"
    fi
  else
    printf '  Claude 配置：未创建\n'
  fi
}

print_banner() {
  command -v clear >/dev/null 2>&1 && clear || true
  printf '%s' "$C_CYAN"
  printf '================================================\n'
  printf '       Termux 电脑端智能体一键安装助手\n'
  printf '                 v%s\n' "$SCRIPT_VERSION"
  printf '================================================\n'
  printf '%s' "$C_RESET"
  printf '  1. 安装 / 更新 Codex\n'
  printf '  2. 安装 / 更新 Claude Code\n'
  printf '  3. 更换 Codex 端点、密钥、模型\n'
  printf '  4. 更换 Claude 端点、密钥、模型\n'
  printf '  5. 一键安装 / 更新 Codex + Claude Code\n'
  printf '  6. 环境诊断\n'
  printf '  7. 测试 OpenAI 中转连接并获取模型列表\n'
  printf '  8. Codex 切换到 DeepSeek（小白推荐）\n'
  printf '  9. 恢复 Codex 中转配置\n'
  printf '  0. 退出\n'
  printf '%s\n' '------------------------------------------------'
}

main() {
  local choice

  preflight || exit 1
  while true; do
    print_banner
    printf '请选择功能 [0-9]: '
    IFS= read -r choice <&3 || break
    printf '\n'
    case "$choice" in
      1) install_codex; pause ;;
      2) install_claude; pause ;;
      3) configure_codex && show_codex_tips; pause ;;
      4) configure_claude && show_claude_tips; pause ;;
      5)
        install_codex
        printf '\n'
        install_claude
        pause
        ;;
      6) diagnose; pause ;;
      7) test_openai_relay; pause ;;
      8) configure_deepseek_codex && show_codex_tips; pause ;;
      9) restore_codex_relay && show_codex_tips; pause ;;
      0) printf '已退出。\n'; break ;;
      *) warn "无效选项，请输入 0 到 9。"; pause ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
