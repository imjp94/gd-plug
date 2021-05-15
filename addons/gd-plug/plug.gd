tool
extends SceneTree

signal updated(plugin)

const VERSION = "0.1.0"
const DEFAULT_PLUGIN_URL = "https://git::@github.com/%s.git"
const DEFAULT_PLUG_DIR = "res://.plugged"
const DEFAULT_CONFIG_PATH = DEFAULT_PLUG_DIR + "/index.cfg"
const DEFAULT_USER_PLUG_SCRIPT_PATH = "res://plug.gd"
const DEFAULT_BASE_PLUG_SCRIPT_PATH = "res://addons/gd-plug/plug.gd"

const ENV_PRODUCTION = "production"

const MSG_PLUG_START_ASSERTION = "_plug_start() must be called first"

var project_dir = Directory.new()
var installation_config = ConfigFile.new()
var logger = Logger.new()

var _installed_plugins
var _plugged_plugins = {}

var _threads = []
var _mutex = Mutex.new()
var _start_time = 0


func _initialize():
	var args = OS.get_cmdline_args()
	# Trim unwanted args passed to godot executable
	for arg in Array(args):
		args.remove(0)
		if "plug.gd" in arg:
			break

	for arg in args:
		# NOTE: "--key" or "-key" will always be consumed by godot executable, see https://github.com/godotengine/godot/issues/8721
		var key = arg.to_lower()
		match key:
			"detail":
				logger.log_format = Logger.DEFAULT_LOG_FORMAT_DETAIL
			"debug", "d":
				logger.log_level = Logger.LogLevel.DEBUG
			"quiet", "q", "silent":
				logger.log_level = Logger.LogLevel.NONE
			"production":
				OS.set_environment(ENV_PRODUCTION, "true")

	logger.debug("cmdline_args: %s" % args)
	_start_time = OS.get_system_time_msecs()
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
				logger.info("upgrade is not implemented yet!")
			"status":
				_plug_status()
			"version":
				logger.info(VERSION)
			_:
				logger.error("Unknown command %s" % args[0])
	quit()

func _finalize():
	_plug_end()
	logger.info("Finished, elapsed %.3fs" % ((OS.get_system_time_msecs() - _start_time) / 1000.0))

func _on_updated(plugin):
	pass

func _plugging():
	pass

# Index installed plugins, or create directory "plugged" if not exists
func _plug_start():
	logger.debug("Plug start")
	if not project_dir.dir_exists(DEFAULT_PLUG_DIR):
		if project_dir.make_dir(ProjectSettings.globalize_path(DEFAULT_PLUG_DIR)) == OK:
			logger.debug("Make dir %s for plugin installation")
	if installation_config.load(DEFAULT_CONFIG_PATH) == OK:
		logger.debug("Installation config loaded")
	else:
		logger.debug("Installation config not found")
	_installed_plugins = installation_config.get_value("plugin", "installed", {})

# Install plugin or uninstall plugin if unlisted
func _plug_end():
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	installation_config.set_value("plugin", "installed", _installed_plugins)
	installation_config.save(DEFAULT_CONFIG_PATH)
	_installed_plugins = null

func _plug_init():
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	logger.info("Init gd-plug...")
	var file = File.new()
	if file.file_exists(DEFAULT_USER_PLUG_SCRIPT_PATH):
		logger.warn("%s already exists!" % DEFAULT_USER_PLUG_SCRIPT_PATH)
	else:
		file.open(DEFAULT_USER_PLUG_SCRIPT_PATH, File.WRITE)
		file.store_string(INIT_PLUG_SCRIPT)
		file.close()
		logger.info("Created %s" % DEFAULT_USER_PLUG_SCRIPT_PATH)

func _plug_install():
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	logger.info("Installing...")
	for plugin in _plugged_plugins.values():
		var installed = plugin.name in _installed_plugins
		if installed:
			var installed_plugin = get_installed_plugin(plugin.name)
			if (installed_plugin.dev or plugin.dev) and OS.get_environment(ENV_PRODUCTION):
				logger.info("Remove dev plugin for production: %s" % plugin.name)
				start_plugin_thread("uninstall_plugin", installed_plugin)
			else:
				start_plugin_thread("update_plugin", plugin)
		else:
			start_plugin_thread("install_plugin", plugin)
	wait_threads()
	for plugin in _installed_plugins.values():
		var removed = not (plugin.name in _plugged_plugins)
		if removed:
			var installed_plugin = get_installed_plugin(plugin.name)
			start_plugin_thread("uninstall_plugin", installed_plugin)
	wait_threads()

func _plug_status():
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	logger.info("Installed %d plugin%s" % [_installed_plugins.size(), "s" if _installed_plugins.size() > 1 else ""])
	var new_plugins = _plugged_plugins.duplicate()
	for plugin in _installed_plugins.values():
		logger.info("- {name} - {url}".format(plugin))
		new_plugins.erase(plugin.name)
		var removed = not (plugin.name in _plugged_plugins)
		if removed:
			logger.info("%s removed" % plugin.name)
	if new_plugins:
		logger.info("\nPlugged %d plugin%s" % [new_plugins.size(), "s" if new_plugins.size() > 1 else ""])
		for plugin in new_plugins.values():
			var is_new = not (plugin.name in _installed_plugins)
			if is_new:
				logger.info("- {name} - {url}".format(plugin))

# Index & validate plugin
func plug(repo, args={}):
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	repo = repo.strip_edges()
	var plugin_name = get_plugin_name_from_repo(repo)
	if plugin_name in _plugged_plugins:
		logger.info("Plugin already plugged: %s" % plugin_name)
		return
	var plugin = {}
	plugin.name = plugin_name
	plugin.url = ""
	if ":" in repo:
		plugin.url = repo
	elif repo.find("/") == repo.rfind("/"):
		plugin.url = DEFAULT_PLUGIN_URL % repo
	else:
		logger.error("Invalid repo: %s" % repo)
	plugin.plug_dir = DEFAULT_PLUG_DIR + "/" + plugin.name

	plugin.include = args.get("include", [])
	plugin.exclude = args.get("exclude", [])
	plugin.branch = args.get("branch", "")
	plugin.tag = args.get("tag", "")
	plugin.commit = args.get("commit", "")
	plugin.dev = args.get("dev", false)
	plugin.on_updated = args.get("on_updated", "")

	_plugged_plugins[plugin.name] = plugin
	logger.debug("Plug: %s" % plugin)

func install_plugin(plugin):
	var can_install = not OS.get_environment(ENV_PRODUCTION) if plugin.dev else true
	if can_install:
		logger.info("Installing plugin %s..." % plugin.name)
		if downlaod(plugin) == OK:
			install(plugin)

func uninstall_plugin(plugin):
	uninstall(plugin)
	directory_delete_recursively(plugin.plug_dir, {"exclude": [DEFAULT_CONFIG_PATH]})

func update_plugin(plugin):
	var installed_plugin = get_installed_plugin(plugin.name)
	var changed_keys = compare_plugins(plugin, installed_plugin)
	var changed = not changed_keys.empty()
	var global_dest_dir = ProjectSettings.globalize_path(plugin.plug_dir)
	var git_executable = GitExecutable.new(global_dest_dir, logger)
	var should_pull = false
	var freezed = !!plugin.branch or !!plugin.tag or !!plugin.commit
	if not freezed:
		var ahead_behind = []
		if git_executable.fetch().exit == OK:
			ahead_behind = git_executable.get_commit_comparison("HEAD", "origin")
		var is_commit_behind = !!ahead_behind[1] if ahead_behind.size() == 2 else false
		if is_commit_behind:
			changed = true
			should_pull = true
		else:
			if not changed:
				logger.info("%s up to date" % plugin.name)
	else:
		if not changed:
			for rev in ["branch", "tag", "commit"]:
				var freeze_at = plugin[rev]
				if freeze_at:
					logger.info("%s frozen at %s \"%s\"" % [plugin.name, rev, freeze_at])
					break
	if changed:
		logger.info("%s changed %s, updating..." % [plugin.name, changed_keys])
		uninstall(installed_plugin)
		var should_clone = "url" in changed_keys or "branch" in changed_keys or "tag" in changed_keys or "commit" in changed_keys
		should_clone = should_clone
		if should_clone:
			logger.info("%s cloning from %s..." % [plugin.name, plugin.url])
			directory_delete_recursively(plugin.plug_dir, {"exclude": [DEFAULT_CONFIG_PATH]})
			if downlaod(plugin) == OK:
				install(plugin)
		elif should_pull:
			logger.info("%s pulling updates from %s..." % [plugin.name, plugin.url])
			if git_executable.pull().exit == OK:
				install(plugin)
		else:
			install(plugin)

func plugin_call(data):
	var method = data.method
	var plugin = data.plugin
	if has_method(method):
		call(method, plugin)
	else:
		logger.error("Unexpected method called: %s" % method)

func start_plugin_thread(method, plugin):
	var data = {}
	data["method"] = method
	data["plugin"] = plugin
	logger.debug("Thread start \"%s\" for plugin %s" % [method, plugin.name])
	return start_thread("plugin_call", data)

func start_thread(method, data):
	var thread = Thread.new()
	_threads.append(thread)
	thread.start(self, method, data)
	logger.debug("Thread start for \"%s\"" % method)
	return thread

func wait_threads():
	if _threads.empty():
		return

	logger.debug("Waiting %d thread%s..." % [_threads.size(), "s" if _threads.size() > 1 else ""])
	for thread in _threads:
		if thread.is_active():
			thread.wait_to_finish()
	_threads.clear()
	logger.debug("All threads joined")

func downlaod(plugin):
	logger.info("Downloading %s from %s..." % [plugin.name, plugin.url])
	var global_dest_dir = ProjectSettings.globalize_path(plugin.plug_dir)
	if project_dir.dir_exists(plugin.plug_dir):
		directory_delete_recursively(plugin.plug_dir)
	project_dir.make_dir(plugin.plug_dir)
	var result = GitExecutable.new(global_dest_dir, logger).clone(plugin.url, global_dest_dir, {"branch": plugin.branch, "tag": plugin.tag, "commit": plugin.commit})
	if result.exit == OK:
		logger.info("Successfully download %s" % [plugin.name])
	else:
		logger.info("Failed to download %s" % plugin.name)
		# Make sure plug_dir is clean when failed
		directory_delete_recursively(plugin.plug_dir, {"exclude": [DEFAULT_CONFIG_PATH]})
	project_dir.remove(plugin.plug_dir) # Remove empty directory
	return result.exit

func install(plugin):
	logger.info("Installing files for %s..." % plugin.name)
	var include = plugin.get("include", [])
	if include.empty(): # Auto include "addons/" folder if not explicitly specified
		include = ["addons/"]
	var dest_files = directory_copy_recursively(plugin.plug_dir, "res://", {"include": include, "exclude": plugin.exclude})
	plugin.dest_files = dest_files
	logger.info("Installed %d file%s for %s" % [dest_files.size(), "s" if dest_files.size() > 1 else "", plugin.name])
	set_installed_plugin(plugin)
	if plugin.on_updated:
		if has_method(plugin.on_updated):
			logger.info("Execute post-update function for %s: %s" % [plugin.name, plugin.do])
			_on_updated(plugin)
			call(plugin.on_updated, plugin.duplicate())
			emit_signal("updated", plugin)

func uninstall(plugin):
	var dest_files = plugin.get("dest_files", [])
	logger.info("Uninstalling %d file%s for %s..." % [dest_files.size(), "s" if dest_files.size() > 1 else "",plugin.name])
	directory_remove_batch(dest_files)
	logger.info("Uninstalled %d file%s for %s" % [dest_files.size(), "s" if dest_files.size() > 1 else "",plugin.name])
	remove_installed_plugin(plugin.name)

# Get installed plugin, thread safe
func get_installed_plugin(plugin_name):
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	_mutex.lock()
	var installed_plugin = _installed_plugins[plugin_name]
	_mutex.unlock()
	return installed_plugin

# Set installed plugin, thread safe
func set_installed_plugin(plugin):
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	_mutex.lock()
	_installed_plugins[plugin.name] = plugin
	_mutex.unlock()

# Remove installed plugin, thread safe
func remove_installed_plugin(plugin_name):
	assert(_installed_plugins != null, MSG_PLUG_START_ASSERTION)
	_mutex.lock()
	var result = _installed_plugins.erase(plugin_name)
	_mutex.unlock()
	return result

func directory_copy_recursively(from, to, args={}):
	var include = args.get("include", [])
	var exclude = args.get("exclude", [])
	var dir = Directory.new()
	var dest_files = []
	if dir.open(from) == OK:
		dir.list_dir_begin(true, true)
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
							logger.debug("Copy from %s to %s" % [source, dest])
						break
			file_name = dir.get_next()
		dir.list_dir_end()
	else:
		logger.error("Failed to access path: %s" % from)
	
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
							logger.debug("Remove empty directory: %s" % sub_dir.get_current_dir())
					else:
						if dir.remove(sub_dir.get_current_dir()) == OK:
							logger.debug("Remove empty directory: %s" % sub_dir.get_current_dir())
			else:
				var excluded = false
				for exclude_key in exclude:
					if source in exclude_key:
						excluded = true
						break
				if not excluded:
					if dir.remove(file_name) == OK:
						logger.debug("Remove file: %s" % source)
			file_name = dir.get_next()
		dir.list_dir_end()
	else:
		logger.error("Failed to access path: %s" % dir_path)

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
			logger.debug("Remove file: " + file)
		if not keep_import_file:
			var import_file = file_name + ".import"
			if dir.remove(import_file) == OK:
				logger.debug("Remove import file: " + file)
	for dir in dirs.values():
		var slash_count = dir.get_current_dir().count("/") - 2 # Deduct 2 slash from "res://"
		if dir.remove(dir.get_current_dir()) == OK:
			logger.debug("Remove empty directory: %s" % dir.get_current_dir())
		# Dumb method to clean empty ancestor directories
		logger.debug("Removing emoty ancestor directory for %s..." % dir.get_current_dir())
		var current_dir = dir.get_current_dir()
		for i in slash_count:
			current_dir = current_dir.get_base_dir()
			var d = Directory.new()
			if d.open(current_dir) == OK:
				if d.remove(d.get_current_dir()) == OK:
					logger.debug("Remove empty ancestor directory: %s" % d.get_current_dir())

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

class GitExecutable extends Reference:
	var cwd = ""
	var logger

	func _init(p_cwd, p_logger):
		cwd = p_cwd
		logger = p_logger

	func _execute(command, blocking=true, output=[], read_stderr=false):
		var cmd = "cd %s && %s" % [cwd, command]
		# NOTE: OS.execute() seems to ignore read_stderr
		var exit = FAILED
		match OS.get_name():
			"Windows":
				cmd = cmd if read_stderr else "%s 2> nul" % cmd
				logger.debug("Execute \"%s\"" % cmd)
				exit = OS.execute("cmd", ["/C", cmd], blocking, output, read_stderr)
			"X11", "OSX":
				cmd if read_stderr else "%s 2>/dev/null" % cmd
				logger.debug("Execute \"%s\"" % cmd)
				exit = OS.execute("bash", ["-c", cmd], blocking, output, read_stderr)
			var unhandled_os:
				logger.error("Unexpected OS: %s" % unhandled_os)
		logger.debug("Execution ended(code:%d): %s" % [exit, output])
		return exit

	func clone(src, dest, args={}):
		logger.debug("Cloning from %s to %s..." % [src, dest])
		var output = []
		var branch = args.get("branch", "")
		var tag = args.get("tag", "")
		var commit = args.get("commit", "")
		var command = "git clone --depth=1 --progress %s %s" % [src, dest]
		if branch or tag:
			command = "git clone --depth=1 --single-branch --branch %s %s %s" % [branch if branch else tag, src, dest]
		var exit = _execute(command, true, output)
		logger.debug("Successfully cloned from %s" % src if exit == OK else "Failed to clone from %s" % src)
		return {"exit": exit, "output": output}

	func fetch(rm="--all"):
		logger.debug("Fetching %s..." % rm.replace("--", ""))
		var output = []
		var exit = _execute("git fetch %s" % rm, true, output)
		logger.debug("Successfully fetched" if exit == OK else "Failed to fetch")
		return {"exit": exit, "output": output}

	func pull():
		logger.debug("Pulling...")
		var output = []
		var exit = _execute("git pull --rebase", true, output)
		logger.debug("Successfully pulled" if exit == OK else "Failed to pull")
		return {"exit": exit, "output": output}

	func get_commit_comparison(branch_a, branch_b):
		var output = []
		var exit = _execute("git rev-list --count --left-right %s...%s" % [branch_a, branch_b], true, output)
		var raw_ahead_behind = output[0].split("\t")
		var ahead_behind = []
		for msg in raw_ahead_behind:
			ahead_behind.append(int(msg))
		return ahead_behind if exit == OK else []

class Logger extends Reference:
	enum LogLevel {
		ALL, DEBUG, INFO, WARN, ERROR, NONE
	}
	const DEFAULT_LOG_FORMAT_DETAIL = "[{time}] [{level}] {msg}"
	const DEFAULT_LOG_FORMAT_NORMAL = "{msg}"
	
	var log_level = LogLevel.INFO
	var log_format = DEFAULT_LOG_FORMAT_NORMAL
	var log_time_format = "{year}/{month}/{day} {hour}:{minute}:{second}"

	func debug(msg, raw=false):
		_log(LogLevel.DEBUG, msg, raw)

	func info(msg, raw=false):
		_log(LogLevel.INFO, msg, raw)

	func warn(msg, raw=false):
		_log(LogLevel.WARN, msg, raw)

	func error(msg, raw=false):
		_log(LogLevel.ERROR, msg, raw)

	func _log(level, msg, raw=false):
		if log_level <= level:
			if raw:
				printraw(format_log(level, msg))
			else:
				print(format_log(level, msg))

	func format_log(level, msg):
		return log_format.format({
			"time": log_time_format.format(get_formatted_datatime()),
			"level": LogLevel.keys()[level],
			"msg": msg
		})

	func get_formatted_datatime():
		var datetime = OS.get_datetime()
		datetime.year = "%04d" % datetime.year
		datetime.month = "%02d" % datetime.month
		datetime.day = "%02d" % datetime.day
		datetime.hour = "%02d" % datetime.hour
		datetime.minute = "%02d" % datetime.minute
		datetime.second = "%02d" % datetime.second
		return datetime
