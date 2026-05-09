#!/usr/bin/env bash

_get_bind_addr() {
  local allow_lan bind_addr
  bind_addr=$("$BIN_YQ" '.bind-address // "*"' "$CLASH_CONFIG_RUNTIME")
  allow_lan=$("$BIN_YQ" '.allow-lan // false' "$CLASH_CONFIG_RUNTIME")

  case $allow_lan in
  true)
    [ "$bind_addr" = "*" ] && bind_addr=$(_get_local_ip)
    ;;
  false)
    bind_addr=127.0.0.1
    ;;
  esac
  printf '%s\n' "$bind_addr"
}

_detect_proxy_port() {
  local mixed_port http_port socks_port
  mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$CLASH_CONFIG_RUNTIME")
  http_port=$("$BIN_YQ" '.port // ""' "$CLASH_CONFIG_RUNTIME")
  socks_port=$("$BIN_YQ" '.socks-port // ""' "$CLASH_CONFIG_RUNTIME")

  [ -z "$mixed_port" ] && [ -z "$http_port" ] && [ -z "$socks_port" ] && mixed_port=7890

  local count=0
  local service_active=false
  service_is_active >&/dev/null && service_active=true

  local entries=(
    "mixed-port:$mixed_port"
    "port:$http_port"
    "socks-port:$socks_port"
  )

  local entry yaml_key port new_port
  for entry in "${entries[@]}"; do
    yaml_key=${entry%%:*}
    port=${entry#*:}

    [ -n "$port" ] && _is_port_used "$port" && [ "$service_active" != "true" ] && {
      new_port=$(_get_random_port)
      count=$((count + 1))
      _failcat '🎯' "端口冲突：[$yaml_key] $port 🎲 随机分配 $new_port"
      "$BIN_YQ" -i ".${yaml_key} = $new_port" "$CLASH_CONFIG_MIXIN"
    }
  done

  [ "$count" -gt 0 ] && _merge_config
}

_detect_ext_addr() {
  local ext_addr
  ext_addr=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME")

  local ext_ip=${ext_addr%%:*}
  local ext_port=${ext_addr##*:}

  EXT_IP=$ext_ip
  EXT_PORT=$ext_port
  [ "$ext_ip" = '0.0.0.0' ] && EXT_IP=$(_get_local_ip)

  _is_port_used "$EXT_PORT" && {
    for pid in $(pgrep -f "$BIN_KERNEL"); do
      [ -z "$pid" ] && continue
      _is_port_used "$pid" && return 0
    done
    local new_port
    new_port=$(_get_random_port)
    _failcat '🎯' "端口冲突：[external-controller] ${EXT_PORT} 🎲 随机分配 $new_port"
    EXT_PORT=$new_port
    "$BIN_YQ" -i ".external-controller = \"$ext_ip:$new_port\"" "$CLASH_CONFIG_MIXIN"
    _merge_config
  }
}

_get_secret() {
  "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME"
}

_valid_config() {
  local config="$1"
  [[ ! -e "$config" || "$(wc -l <"$config")" -lt 1 ]] && return 1

  local test_cmd test_log
  test_cmd=("$BIN_KERNEL" -d "$(dirname "$config")" -f "$config" -t)
  test_log=$("${test_cmd[@]}") || {
    "${test_cmd[@]}"
    grep -qs "unsupport proxy type" <<<"$test_log" && {
      local prefix="检测到订阅中包含不受支持的代理协议"
      [ "$CLASHCTL_KERNEL" = "clash" ] && _error_quit "${prefix}, 推荐安装使用 mihomo 内核"
      _error_quit "${prefix}, 请检查并升级内核版本"
    }
    return 1
  }
}

_merge_config() {
  cat "$CLASH_CONFIG_RUNTIME" >"$CLASH_CONFIG_TEMP" 2>/dev/null
  # shellcheck disable=SC2016
  "$BIN_YQ" eval-all '
      ########################################
      #              Load Files              #
      ########################################
      select(fileIndex==0) as $config |
      select(fileIndex==1) as $mixin |

      ########################################
      #              Deep Merge              #
      ########################################
      $mixin |= del(._custom) |
      (($config // {}) * $mixin) as $runtime |
      $runtime |

      ########################################
      #               Rules                  #
      ########################################
      .rules = (
        ($mixin.rules.prepend // []) +
        ($config.rules // []) +
        ($mixin.rules.append // [])
      ) |

      ########################################
      #                Proxies               #
      ########################################
      .proxies = (
        ($mixin.proxies.prepend // []) +
        (
          ($config.proxies // []) as $configList |
          ($mixin.proxies.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxies.append // [])
      ) |

      ########################################
      #             ProxyGroups              #
      ########################################
      .proxy-groups = (
        ($mixin.proxy-groups.prepend // []) +
        (
          ($config.proxy-groups // []) as $configList |
          ($mixin.proxy-groups.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxy-groups.append // [])
      ) |

      ########################################
      #         ProxyGroups Inject           #
      ########################################
      ($mixin.proxy-groups.inject // {}) as $inj |
      .proxy-groups[] |= (
        . as $g |
        ($inj | .[$g.name] // []) as $extra |
        .proxies = (.proxies + $extra | unique)
      )
    ' "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_MIXIN" >"$CLASH_CONFIG_RUNTIME"

  _valid_config "$CLASH_CONFIG_RUNTIME" || {
    cat "$CLASH_CONFIG_TEMP" >"$CLASH_CONFIG_RUNTIME"
    _error_quit "验证失败：请检查 Mixin 配置"
  }
}
tunstatus() {
  local device
  device=$("$BIN_YQ" '.tun.device // ""' "$CLASH_CONFIG_RUNTIME")
  [ -z "$device" ] && device="Meta"
  ip link show | grep -qs "$device" && {
    _okcat 'Tun 状态：启用'
    return 0
  }
  _failcat 'Tun 状态：关闭'
  return 1
}
_merge_config_restart() {
  _merge_config
  service_stop >&/dev/null
  service_is_active >&/dev/null && tunstatus >&/dev/null && {
    service_sudo_stop || _error_quit "请先关闭 Tun 模式"
  }
  sleep 0.1
  service_start >/dev/null
}
