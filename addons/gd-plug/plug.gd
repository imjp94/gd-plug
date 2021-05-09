tool
extends SceneTree

signal updated(plugin)

const VERSION = "0.1.0"
const DEFAULT_PLUGIN_URL = "https://git::@github.com/%s.git"
const DEFAULT_PLUG_DIR = "res://.plugged"
const DEFAULT_CONFIG_PATH = DEFAULT_PLUG_DIR + "/index.cfg"
const DEFAULT_USER_PLUG_SCRIPT_PATH = "res://plug.gd"
const DEFAULT_BASE_PLUG_SCRIPT_PATH = "res://addons/gd-plug/plug.gd"

const MSG_PLUG_START_ASSERTION = "_plug_start() must be called first"

var project_dir = Directory.new()
var installation_config = ConfigFile.new()

var _installed_plugins
var _plugged_plugins = {}


func _initialize():
	var args = OS.get_cmdline_args()
	# Trim unwanted args passed to godot executable
	for arg in Array(args):
		args.remove(0)
		if "plug.gd" in arg:
			break

	_plug_start()
	if args.size() > 0:
		_plugging()
		match args[0]:
			"init":
				_plug_init()
			"install", "update":
				_plug_install()
			"upgrade":
				# TODO: Upgrade gd-plug itself
				pass
			"status":
				_plug_status()
			"version":
				print(VERSION)
			_:
				print("Unknown command %s" % args[0])
	quit()

func _finalize():
	_plug_end()

func _on_updated(plugin):
	pass

func _plugging():
	pass

# Index installed plugins, or create directory "plugged" if not exists
func _plug_start():
	if not project_dir.dir_exists(DEFAULT_PLUG_DIR):
		var result = project_dir.make_dir(ProjectSettings.globalize_path(DEFAULT_PLUG_DIR))
		print(result == OK)
	if installation_config.load(DEFAULT_CONFIG_PATH) == OK:
		print("Installation config loaded")
	else:
		print("Installation config not found")
	_installed_plugins = installation_config.get_value("plugin", "installed", {})

# Install plugin or uninstall plugin if unlisted
func _plug_end():
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	installation_config.set_value("plugin", "installed", _installed_plugins)
	installation_config.save(DEFAULT_CONFIG_PATH)
	_installed_plugins = null

func _plug_init():
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	print("Init gd-plug...")
	var file = File.new()
	if file.file_exists(DEFAULT_USER_PLUG_SCRIPT_PATH):
		print("%s already exists!" % DEFAULT_USER_PLUG_SCRIPT_PATH)
	else:
		file.open(DEFAULT_USER_PLUG_SCRIPT_PATH, File.WRITE)
		file.store_string(INIT_PLUG_SCRIPT)
		file.close()
		print("Created %s" % DEFAULT_USER_PLUG_SCRIPT_PATH)

func _plug_install():
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	for plugin in _plugged_plugins.values():
		var installed = plugin.name in _installed_plugins
		if installed:
			var installed_plugin = _installed_plugins[plugin.name]
			var changed_keys = compare_plugins(plugin, installed_plugin)
			var changed = not changed_keys.empty()
			if changed:
				uninstall(installed_plugin)
				print("%s changed %s" % [plugin.name, changed_keys])
				if "url" in changed_keys:
					directory_delete_recursively(plugin.plug_dir, {"exclude": [DEFAULT_CONFIG_PATH]})
					if downlaod(plugin):
						install(plugin)
				else:
					install(plugin)
		else:
			if downlaod(plugin) == OK:
				install(plugin)
	for plugin in _installed_plugins.values():
		var removed = not (plugin.name in _plugged_plugins)
		if removed:
			uninstall(plugin)
			directory_delete_recursively(plugin.plug_dir, {"exclude": [DEFAULT_CONFIG_PATH]})

func _plug_status():
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	print("Installed %d plugin%s" % [_installed_plugins.size(), "s" if _installed_plugins.size() > 1 else ""])
	var new_plugins = _plugged_plugins.duplicate()
	for plugin in _installed_plugins.values():
		print("- {name} - {url}".format(plugin))
		new_plugins.erase(plugin.name)
		var removed = not (plugin.name in _plugged_plugins)
		if removed:
			print("%s removed" % plugin.name)
	if new_plugins:
		print("\nAdded %d plugin%s" % [new_plugins.size(), "s" if new_plugins.size() > 1 else ""])
		for plugin in new_plugins.values():
			var is_new = not (plugin.name in _installed_plugins)
			if is_new:
				print("- {name} - {url}".format(plugin))

# Index & validate plugin
func plug(repo, args={}):
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	repo = repo.strip_edges()
	var plugin_name = get_plugin_name_from_repo(repo)
	if plugin_name in _plugged_plugins:
		print("Plugin already plugged: %s" % plugin_name)
		return
	var plugin = {}
	plugin.name = plugin_name
	plugin.url = ""
	if ":" in repo:
		plugin.url = repo
	elif repo.find("/") == repo.rfind("/"):
		plugin.url = DEFAULT_PLUGIN_URL % repo
	else:
		push_error("Invalid repo: %s" % repo)
	plugin.plug_dir = DEFAULT_PLUG_DIR + "/" + plugin.name

	plugin.include = args.get("include", [])
	plugin.exclude = args.get("exclude", [])
	plugin.branch = args.get("branch", "")
	plugin.tag = args.get("tag", "")
	plugin.commit = args.get("commit", "")
	plugin.dev = args.get("dev", false)
	plugin.on_updated = args.get("on_updated", "")

	_plugged_plugins[plugin.name] = plugin

func downlaod(plugin):
	var global_dest_dir = ProjectSettings.globalize_path(plugin.plug_dir)
	if project_dir.dir_exists(plugin.plug_dir):
		directory_delete_recursively(plugin.plug_dir)
	project_dir.make_dir(plugin.plug_dir)
	var output = []
	var code = OS.execute("git", ["clone", "--depth=1", "--progress", plugin.url, global_dest_dir], true, output)
	printt(plugin.url, installation_config, code, output, plugin.name)
	print("Success!" if code == OK else "Failed!")
	project_dir.remove(plugin.plug_dir) # Remove empty directory
	return code

func install(plugin):
	var include = plugin.get("include", [])
	if include.empty(): # Auto include "addons/" folder if not explicitly specified
		include = ["addons/"]
	var dest_files = directory_copy_recursively(plugin.plug_dir, "res://", {"include": include, "exclude": plugin.exclude})
	plugin.dest_files = dest_files
	if plugin.on_updated:
		if has_method(plugin.on_updated):
			_on_updated(plugin)
			call(plugin.on_updated, plugin.duplicate())
			emit_signal("updated", plugin)
	_installed_plugins[plugin.name] = plugin

func uninstall(plugin):
	directory_remove_batch(plugin.get("dest_files", []))
	_installed_plugins.erase(plugin.name)

func directory_copy_recursively(from, to, args={}):
	var include = args.get("include", [])
	var exclude = args.get("exclude", [])
	var dir = Directory.new()
	var dest_files = []
	if dir.open(from) == OK:
		dir.list_dir_begin(true, true)
		printt("opened dir %s" % from)
		var file_name = dir.get_next()
		while not file_name.empty():
			var source = dir.get_current_dir() + ("/" if dir.get_current_dir() != "res://" else "") + file_name
			var dest = to + ("/" if to != "res://" else "") + file_name
			
			if dir.current_is_dir():
				dest_files += directory_copy_recursively(source, dest, args)
			else:
				for include_key in include:
					if include_key in source:
						var is_excluded = false
						for exclude_key in exclude:
							if exclude_key in source:
								is_excluded = true
								break
						if not is_excluded:
							dir.make_dir_recursive(to)
							dir.copy(source, dest)
							dest_files.append(dest)
							print("Move from %s to %s" % [source, dest])
						break
			file_name = dir.get_next()
		dir.list_dir_end()
	else:
		print("Failed to access path: %s" % from)
	
	return dest_files

func directory_delete_recursively(dir_path, args={}):
	var remove_empty_directory = args.get("remove_empty_directory", true)
	var exclude = args.get("exclude", [])
	var dir = Directory.new()
	if dir.open(dir_path) == OK:
		dir.list_dir_begin(true, false)
		var file_name = dir.get_next()
		while not file_name.empty():
			var source = dir.get_current_dir() + ("/" if dir.get_current_dir() != "res://" else "") + file_name
			
			if dir.current_is_dir():
				var sub_dir = directory_delete_recursively(source, args)
				if remove_empty_directory:
					if source.get_file() == ".git":
						# Hacks to remove .git, as git pack files stop it from being removed
						# See https://stackoverflow.com/questions/1213430/how-to-fully-delete-a-git-repository-created-with-init
						if OS.execute("rm", ["-rf", ProjectSettings.globalize_path(source)]) == OK:
							print("Remove empty directory: %s" % sub_dir.get_current_dir())
					else:
						if dir.remove(sub_dir.get_current_dir()) == OK:
							print("Remove empty directory: %s" % sub_dir.get_current_dir())
			else:
				var excluded = false
				for exclude_key in exclude:
					if source in exclude_key:
						excluded = true
						break
				if not excluded:
					if dir.remove(file_name) == OK:
						print("Remove file: %s" % source)
			file_name = dir.get_next()
		dir.list_dir_end()
	else:
		print("Failed to access path: %s" % dir_path)

	if remove_empty_directory:
		dir.remove(dir.get_current_dir())

	return dir

func directory_remove_batch(files, args={}):
	var remove_empty_directory = args.get("remove_empty_directory", true)
	var keep_import_file = args.get("keep_import_file", false)
	var dirs = {}
	for file in files:
		var file_dir = file.get_base_dir()
		var file_name =file.get_file()
		var dir = dirs.get(file_dir)
		
		if not dir:
			dir = Directory.new()
			dir.open(file_dir)
			dirs[file_dir] = dir

		if dir.remove(file_name) == OK:
			print("Remove file: ", file)
		if not keep_import_file:
			var import_file = file_name + ".import"
			if dir.remove(import_file) == OK:
				print("Remove import file: ", file)
	for dir in dirs.values():
		var slash_count = dir.get_current_dir().count("/") - 2 # Deduct 2 slash from "res://"
		if dir.remove(dir.get_current_dir()) == OK:
			print("Remove empty directory: %s" % dir.get_current_dir())
		# Dumb method to clean empty ancestor directories
		var current_dir = dir.get_current_dir()
		for i in slash_count:
			current_dir = current_dir.get_base_dir()
			var d = Directory.new()
			if d.open(current_dir) == OK:
				d.remove(d.get_current_dir())
			else:
				break

func compare_plugins(p1, p2):
	var changed_keys = []
	for key in p1.keys():
		var v1 = p1[key]
		var v2 = p2[key]
		if v1 != v2:
			changed_keys.append(key)
	return changed_keys

func get_plugin_name_from_repo(repo):
	repo = repo.replace(".git", "").trim_suffix("/")
	return repo.get_file()

const INIT_PLUG_SCRIPT = \
"""extends "res://addons/gd-plug/plug.gd"

func _plugging():
	# Declare plugins with plug(repo, args)
	# For example, clone from github repo("user/repo_name")
	# plug("imjp94/gd-YAFSM") # By default, gd-plug will only install anything from "addons/" directory
	# Or you can explicitly specify which file/directory to include
	# plug("imjp94/gd-YAFSM", {"include": ["addons/"]}) # By default, gd-plug will only install anything from "addons/" directory
	pass
"""
