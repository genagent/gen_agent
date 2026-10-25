# Sourced by packaged entrypoints; no credentials or state are involved.
# OpenSSL's legacy provider is dynamically loaded, so Mach-O linkage alone is
# insufficient. Bootstrap BEAM using the packaged modules, then restore the
# caller's environment before admitting provider CLI subprocesses.
runtime_crypto_restore='case System.get_env("GEN_AGENT_DELEGATE_BOOT_OPENSSL_MODULES_WAS_SET") do "1" -> System.put_env("OPENSSL_MODULES", System.get_env("GEN_AGENT_DELEGATE_BOOT_OPENSSL_MODULES_VALUE") || ""); "0" -> System.delete_env("OPENSSL_MODULES"); _ -> :ok end; System.delete_env("GEN_AGENT_DELEGATE_BOOT_OPENSSL_MODULES_WAS_SET"); System.delete_env("GEN_AGENT_DELEGATE_BOOT_OPENSSL_MODULES_VALUE");'

configure_runtime_crypto() {
  bundled_modules=
  for crypto_dir in "$1"/runtime/lib/crypto-*/priv/lib; do
    if [ -d "$crypto_dir/ossl-modules" ]; then
      if [ -n "$bundled_modules" ]; then
        printf '%s\n' 'Ambiguous bundled OpenSSL modules; re-extract the complete package.' >&2
        return 1
      fi
      bundled_modules="$crypto_dir/ossl-modules"
    fi
  done
  [ -n "$bundled_modules" ] || return 0

  if [ "${OPENSSL_MODULES+x}" = x ]; then
    export GEN_AGENT_DELEGATE_BOOT_OPENSSL_MODULES_WAS_SET=1
    export GEN_AGENT_DELEGATE_BOOT_OPENSSL_MODULES_VALUE="$OPENSSL_MODULES"
  else
    export GEN_AGENT_DELEGATE_BOOT_OPENSSL_MODULES_WAS_SET=0
    unset GEN_AGENT_DELEGATE_BOOT_OPENSSL_MODULES_VALUE
  fi
  export OPENSSL_MODULES="$bundled_modules"
}
