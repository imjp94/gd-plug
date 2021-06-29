# Changelog

## 0.1.1

- Bugfixes:
  - Fix [Inner class name conflict with other plugins](https://github.com/imjp94/gd-plug/issues/4)
- Features:
  - [Support for headless/server builds](https://github.com/imjp94/gd-plug/pull/1)

## 0.1.0

Initial release

- Features:
  - Config in GDScript
  - Commandline friendly
  - Multi-threaded download/installation
  - Support freezing plugin with branch/tag/commit
  - Safe installation, installation will be terminated when plugin files found to be overwritting project files(can be switched off with `force` command)
  - Clean .import files and import resources located in /.import when plugin uninstalled
