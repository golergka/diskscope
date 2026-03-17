# Pro Module Submodule

The paid daemon module is expected at:

- `pro/diskscope-pro-daemon`

This path is configured as a git submodule in `.gitmodules`.

If the private submodule is not available, OSS builds continue to work with the
stub `NoProMonitor` capability implementation.
