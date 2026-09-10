#!/bin/bash
# 反代连通性自检脚本
# 作用：验证 git.5671234.xyz 对 raw / api / release（含重定向）三类 GitHub 地址是否可用。
# 用法：bash verify-proxy.sh            （直连）
#       bash verify-proxy.sh socks5h://127.0.0.1:10808   （走本地 s5 代理测试）
set -u

GH_PROXY="https://git.5671234.xyz"
PROXY_ARG=""
[ -n "${1:-}" ] && PROXY_ARG="--proxy $1"

pass=0
fail=0

_chk() { # 名称 期望关键字 URL [range]
    local name="$1" want="$2" url="$3" range="${4:-}" out code
    out=$(mktemp)
    if [ -n "$range" ]; then
        code=$(curl -sSL --max-time 40 $PROXY_ARG -r "$range" -o "$out" -w '%{http_code}' "$url" 2>/dev/null)
    else
        code=$(curl -sSL --max-time 40 $PROXY_ARG -o "$out" -w '%{http_code}' "$url" 2>/dev/null)
    fi
    case "$code" in
        200|206)
            if [ -z "$want" ] || grep -qa -- "$want" "$out"; then
                echo "  [PASS] $name (HTTP $code)"
                pass=$((pass + 1))
            else
                echo "  [FAIL] $name (HTTP $code 但内容不含 '$want')"
                fail=$((fail + 1))
            fi
            ;;
        *)
            echo "  [FAIL] $name (HTTP ${code:-无响应})"
            fail=$((fail + 1))
            ;;
    esac
    rm -f "$out"
}

P="${GH_PROXY}/https://raw.githubusercontent.com/0xdabiaoge/singbox-lite/main"
echo "== 1. raw 源码（脚本本体与各组件）=="
for f in singbox.sh advanced_relay.sh parser.sh xray_manager.sh; do
    _chk "raw ${f}" "#!/bin/bash" "${P}/${f}"
done
_chk "raw singbox.sh?v=缓存参数" "#!/bin/bash" "${P}/singbox.sh?v=1"

echo "== 2. api.github.com 发布信息 =="
A="${GH_PROXY}/https://api.github.com"
_chk "api sing-box latest"  '"assets"' "${A}/repos/SagerNet/sing-box/releases/latest"
_chk "api sing-box tags v1.13.21" '"tag_name"' "${A}/repos/SagerNet/sing-box/releases/tags/v1.13.21"
_chk "api cloudflared latest" '"assets"' "${A}/repos/cloudflare/cloudflared/releases/latest"
_chk "api mikefarah/yq latest" '"tag_name"' "${A}/repos/mikefarah/yq/releases/latest"

echo "== 3. release 二进制（含 302 跳转到 release-assets 的反代改写）=="
G="${GH_PROXY}/https://github.com"
_chk "sing-box-1.13.21-linux-amd64.tar.gz" ""  "${G}/SagerNet/sing-box/releases/download/v1.13.21/sing-box-1.13.21-linux-amd64.tar.gz" 0-15
_chk "cloudflared-linux-amd64"              ""  "${G}/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" 0-15
_chk "yq_linux_amd64"                       ""  "${G}/mikefarah/yq/releases/latest/download/yq_linux_amd64" 0-15
_chk "Xray-linux-64.zip"                    ""  "${G}/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" 0-15

echo "== 4. 端到端：API 取 browser_download_url -> 反代转换 -> 真实下载 =="
sed -n '/^GH_PROXY_BASE=/,/^}/p' "$(dirname "$0")/singbox.sh" > /tmp/.gh_proxy_fn.$$ 2>/dev/null
if command -v jq >/dev/null 2>&1 && [ -s /tmp/.gh_proxy_fn.$$ ]; then
    # shellcheck disable=SC1090
    . /tmp/.gh_proxy_fn.$$
    json=$(curl -fsSL $PROXY_ARG --max-time 40 "${A}/repos/SagerNet/sing-box/releases/latest" 2>/dev/null)
    tag=$(printf '%s' "$json" | jq -r '.tag_name // empty')
    raw_url=$(printf '%s' "$json" | jq -r '[.assets[] | select(.name | endswith("linux-amd64.tar.gz"))][0].browser_download_url // empty')
    proxied=$(_gh_proxy_url "$raw_url")
    echo "  官方地址: ${raw_url}"
    echo "  反代地址: ${proxied}"
    if [ "$proxied" = "${G}/SagerNet/sing-box/releases/download/${tag}/sing-box-${tag#v}-linux-amd64.tar.gz" ]; then
        echo "  [PASS] 转换结果与脚本内校验地址一致"
        pass=$((pass + 1))
    else
        echo "  [FAIL] 转换结果与脚本内校验地址不一致"
        fail=$((fail + 1))
    fi
    code=$(curl -sSL $PROXY_ARG --max-time 40 -r 0-15 -o /tmp/.gh_e2e.$$ -w '%{http_code}' "$proxied" 2>/dev/null)
    if [ "$code" = "206" ] || [ "$code" = "200" ]; then
        echo "  [PASS] 反代地址可下载 (HTTP $code)"
        pass=$((pass + 1))
    else
        echo "  [FAIL] 反代地址下载失败 (HTTP ${code:-无响应})"
        fail=$((fail + 1))
    fi
    rm -f /tmp/.gh_e2e.$$
else
    echo "  [SKIP] 未安装 jq 或找不到 singbox.sh，跳过端到端测试"
fi
rm -f /tmp/.gh_proxy_fn.$$

echo
echo "结果：PASS=${pass} FAIL=${fail}"
[ "$fail" -eq 0 ]
