require "moon"
require "moonscript"

require "lfs"
require "cosmo"
require "yaml"
discount = require "discount"

module "sitegen", package.seeall

import insert, concat, sort from table
import dump, extend, bind_methods, run_with_scope from moon

export create_site, register_plugin
export Plugin

plugins = {}
register_plugin = (plugin) ->
  table.insert plugins, plugin

require "sitegen.common"

log = (...) ->
  print ...

class Plugin -- uhh
  new: (@tpl_scope) =>

class Renderer
  new: (@pattern) =>
  render: -> error "must provide render method"
  can_render: (fname) =>
    nil != fname\match @pattern

  parse_header: (text) =>
    header = {}
    s, e = text\find "%-%-\n"
    if s
      header = yaml.load text\sub 1, s - 1
      text = text\sub e

    text, header

  render: (text, site) =>
    @parse_header text

class HTMLRenderer extends Renderer
  ext: "html"
  pattern: convert_pattern "*.html"

class MarkdownRenderer extends Renderer
  ext: "html"
  pattern: convert_pattern "*.md"

  render: (text, site) =>
    text, header = @parse_header text
    discount(text), header

-- visible from init
class SiteScope
  new: (@site) =>
    @files = OrderSet!
    @copy_files = OrderSet!
    @filters = {}

  set: (name, value) => self[name] = value
  get: (name) => self[name]

  add: (...) =>
    files = flatten_args ...
    @files\add fname for fname in *files

  copy: (...) =>
    files = flatten_args ...
    @copy_files\add fname for fname in *files

  filter: (pattern, fn) =>
    table.insert @filters, {pattern, fn}

  search: (pattern, dir=".", enter_dirs=false) =>
    pattern = convert_pattern pattern
    search = (dir) ->
      for fname in lfs.dir dir
        if not fname\match "^%."
          full_path = Path.join dir, fname
          if enter_dirs and "directory" == lfs.attributes full_path, "mode"
            search full_path
          elseif fname\match pattern
            @files\add full_path

    search dir

  dump_files: =>
    print "added files:"
    for path in @files\each!
      print " * " .. path
    print!
    print "copy files:"
    for path in @copy_files\each!
      print " * " .. path

class Templates
  defaults: require "sitegen.default.templates"
  base_helpers: {
    wrap: (args) ->
      tpl_name = unpack args
      error "missing template name", 2 if not tpl_name

    each: (args) ->
      list, name = unpack args
      if list
        list = flatten_args list
        for item in *list
          cosmo.yield { [(name)]: item }
      nil
  }

  new: (@dir) =>
    @template_cache = {}
    @plugin_helpers = {}
    @base_helpers = extend @plugin_helpers, @base_helpers

  fill: (name, context) =>
    tpl = @get_template name
    tpl context

  get_template: (name) =>
    if not @template_cache[name]
      file = io.open Path.join @dir, name .. ".html"
      @template_cache[name] = if file
        -- load template helper if it exists
        fn, err = moonscript.loadfile Path.join @dir, name .. ".moon"
        if fn
          scope = extend {}, getfenv fn
          setfenv fn, scope
          fn!
          -- TODO
          error "template alongside helpers don't work yet"

        cosmo.f file\read "*a"
      elseif @defaults[name]
        cosmo.f @defaults[name]
      else
        error "could not find template: " .. name if not file

    @template_cache[name]

-- an individual page
class Page
  new: (@site, @source) =>
    @renderer = @site\renderer_for @source
    @target = @site\output_path_for @source, @renderer.ext

    -- extract metadata
    @raw_text, @meta = @renderer\render @_read!

    filter = @site\filter_for @source
    if filter
      @raw_text = filter(@meta, @raw_text) or @raw_text

    -- expose meta in self
    cls = getmetatable self
    extend self, (key) => cls[key] or @meta[key]

  link_to: =>
    front = "^"..escape_patt @site.config.out_dir
    html.build ->
      a { @title, href: @target\gsub front, "" }

  -- write the file, return path to written file
  write: =>
    content = @_render!
    Path.mkdir Path.basepath @target
    with io.open @target, "w"
      \write content
      \close!
    log "rendered", @source, "->", @target
    @target

  -- read the source
  _read: =>
    text = nil
    with io.open @source
      text = \read"*a"
      \close!
    text

  _render: =>
    tpl_scope = {
      body: @raw_text
      generate_date: os.date!
    }

    helpers = @site\template_helpers tpl_scope

    base = Path.basepath @target
    parts = for i = 1, #split(base, "/") - 1 do ".."
    root = table.concat parts, "/"
    root = "." if root == ""
    helpers.root = root

    tpl_scope = extend tpl_scope, @meta, @site.user_vars, helpers

    -- we run the page as a cosmo template until it normalizes
    -- this is because some plugins might need to read/change
    -- the content of the body (see indexer)
    while true
      co = coroutine.create ->
        tpl_scope.body = cosmo.f(tpl_scope.body) tpl_scope
        nil

      pass, altered_body = coroutine.resume co
      error altered_body if not pass
      if altered_body
        tpl_scope.body = altered_body
      else
        break

    -- find the wrapping template
    tpl_name = if @meta.template == nil
      @site.config.default_template
    else
      @meta.template

    if tpl_name
      @site.templates\fill tpl_name, tpl_scope
    else
      tpl_scope.body

-- a webpage
class Site
  config: {
    template_dir: "templates/"
    default_template: "index"
    out_dir: "www/"
    write_gitignore: true
  }

  new: =>
    @templates = Templates @config.template_dir
    @scope = SiteScope self

    @user_vars = {}
    @written_files = {}

    @renderers = {
      MarkdownRenderer
      HTMLRenderer
    }

    @plugins = OrderSet plugins
    -- extract aggregators from plugins
    @aggregators = {}
    for plugin in @plugins\each!
      if plugin.type_name
        for name in *make_list plugin.type_name
          @aggregators[name] = plugin

      if plugin.on_site
        plugin\on_site self

  plugin_scope: =>
    scope = {}
    for plugin in @plugins\each!
      if plugin.mixin_funcs
        for fn_name in *plugin.mixin_funcs
          scope[fn_name] = bound_fn plugin, fn_name

    scope

  init_from_fn: (fn) =>
    bound = bind_methods @scope
    bound = extend @plugin_scope!, bound
    run_with_scope fn, bound, @user_vars

  output_path_for: (path, ext) =>
    if path\match"^%./"
      path = path\sub 3

    path = path\gsub "%.[^.]+$", "." .. ext
    Path.join @config.out_dir, path

  renderer_for: (path) =>
    for renderer in *@renderers
      if renderer\can_render path
        return renderer

    error "Don't know how to render:", path

  -- TODO: refactor to use this?
  write_file: (fname, content) =>
    full_path = Path.join @config.out_dir, fname
    Path.mkdir Path.basepath full_path

    with io.open full_path, "w"
      \write content
      \close!

    table.insert @written_files, full_path
  
  -- strips the out_dir from the file paths
  write_gitignore: (written_files) =>
    with io.open @config.out_dir .. ".gitignore", "w"
      patt = "^" .. escape_patt(@config.out_dir) .. "(.+)$"
      relative = [fname\match patt for fname in *written_files]
      \write concat relative, "\n"
      \close!

  filter_for: (path) =>
    path = Path.normalize path
    for filter in *@scope.filters
      patt, fn = unpack filter
      if path\match patt
        return fn
    nil

  -- get template helpers from plugins
  -- template plugins instances with tpl_scope
  template_helpers: (tpl_scope) =>
    helpers = {}
    for plugin in @plugins\each!
      if plugin.tpl_helpers
        p = plugin tpl_scope
        for helper_name in *plugin.tpl_helpers
          helpers[helper_name] = (...) ->
            p[helper_name] p, ...

    extend helpers, @templates.base_helpers

  -- write the entire website
  write: =>
    pages = for path in @scope.files\each!
      page = Page self, path
      -- TODO: check dont_write
      for t in *make_list page.meta.is_a
        plugin = @aggregators[t]
        error "unknown `is_a` type: " .. t if not plugin
        plugin\on_aggregate page
      page

    written_files = for page in *pages
      page\write!

    -- copy files
    for path in @scope.copy_files\each!
      target = Path.join @config.out_dir, path
      print "copied", target
      table.insert written_files, target
      Path.copy path, target

    -- write plugins
    for plugin in @plugins\each!
      plugin\write self if plugin.write

    -- gitignore
    if @config.write_gitignore
      -- add other written files
      table.insert written_files, file for file in *@written_files
      @write_gitignore written_files

create_site = (init_fn) ->
  with Site!
    \init_from_fn init_fn
    .scope\search "*md"

-- plugin providers
require "sitegen.deploy"
require "sitegen.indexer"
require "sitegen.extra"
require "sitegen.blog"

