# encoding: utf-8

module Nanoc::Int
  # The in-memory representation of a nanoc site. It holds references to the
  # following site data:
  #
  # * {#items}         — the list of items         ({Nanoc::Int::Item})
  # * {#layouts}       — the list of layouts       ({Nanoc::Int::Layout})
  # * {#code_snippets} — the list of code snippets ({Nanoc::Int::CodeSnippet})
  # * {#data_sources}  — the list of data sources  ({Nanoc::DataSource})
  #
  # In addition, each site has a {#config} hash which stores the site
  # configuration.
  #
  # The physical representation of a {Nanoc::Int::Site} is usually a directory
  # that contains a configuration file, site data, a rakefile, a rules file,
  # etc. The way site data is stored depends on the data source.
  #
  # @api private
  class Site
    # The default configuration for a data source. A data source's
    # configuration overrides these options.
    DEFAULT_DATA_SOURCE_CONFIG = {
      type: 'filesystem_unified',
      items_root: '/',
      layouts_root: '/',
      config: {}
    }

    # The default configuration for a site. A site's configuration overrides
    # these options: when a {Nanoc::Int::Site} is created with a configuration
    # that lacks some options, the default value will be taken from
    # `DEFAULT_CONFIG`.
    DEFAULT_CONFIG = {
      text_extensions: %w( css erb haml htm html js less markdown md php rb sass scss txt xhtml xml coffee hb handlebars mustache ms slim ).sort,
      lib_dirs: %w( lib ),
      commands_dirs: %w( commands ),
      output_dir: 'output',
      data_sources: [{}],
      index_filenames: ['index.html'],
      enable_output_diff: false,
      prune: { auto_prune: false, exclude: ['.git', '.hg', '.svn', 'CVS'] }
    }

    # Creates a site object for the site specified by the given
    # `dir_or_config_hash` argument.
    #
    # @param [Hash, String] dir_or_config_hash If a string, contains the path
    #   to the site directory; if a hash, contains the site configuration.
    def initialize(dir_or_config_hash)
      build_config(dir_or_config_hash)
    end

    # Compiles the site.
    #
    # @return [void]
    #
    # @since 3.2.0
    def compile
      compiler.run
    end

    # Returns the compiler for this site. Will create a new compiler if none
    # exists yet.
    #
    # @return [Nanoc::Int::Compiler] The compiler for this site
    def compiler
      @compiler ||= Nanoc::Int::Compiler.new(self)
    end

    # Returns the data sources for this site. Will create a new data source if
    # none exists yet.
    #
    # @return [Array<Nanoc::DataSource>] The list of data sources for this
    #   site
    #
    # @raise [Nanoc::Int::Errors::UnknownDataSource] if the site configuration
    #   specifies an unknown data source
    def data_sources
      load_code_snippets

      @data_sources ||= begin
        @config[:data_sources].map do |data_source_hash|
          # Get data source class
          data_source_class = Nanoc::DataSource.named(data_source_hash[:type])
          raise Nanoc::Int::Errors::UnknownDataSource.new(data_source_hash[:type]) if data_source_class.nil?

          # Create data source
          data_source_class.new(
            self,
            data_source_hash[:items_root],
            data_source_hash[:layouts_root],
            data_source_hash.merge(data_source_hash[:config] || {})
          )
        end
      end
    end

    # Returns this site’s code snippets.
    #
    # @return [Array<Nanoc::Int::CodeSnippet>] The list of code snippets in this
    #   site
    def code_snippets
      load
      @code_snippets
    end

    # Returns this site’s items.
    #
    # @return [Array<Nanoc::Int::Item>] The list of items in this site
    def items
      load
      @items
    end

    # Returns this site’s layouts.
    #
    # @return [Array<Nanoc::Int::Layouts>] The list of layout in this site
    def layouts
      load
      @layouts
    end

    # Returns the site configuration. It has the following keys:
    #
    # * `text_extensions` (`Array<String>`) - A list of file extensions that
    #   will cause nanoc to threat the file as textual instead of binary. When
    #   the data source finds a content file with an extension that is
    #   included in this list, it will be marked as textual.
    #
    # * `output_dir` (`String`) - The directory to which compiled items will
    #   be written. This path is relative to the current working directory,
    #   but can also be an absolute path.
    #
    # * `data_sources` (`Array<Hash>`) - A list of data sources for this site.
    #   See below for documentation on the structure of this list. By default,
    #   there is only one data source of the filesystem  type mounted at `/`.
    #
    # * `index_filenames` (`Array<String>`) - A list of filenames that will be
    #   stripped off full item paths to create cleaner URLs. For example,
    #   `/about/` will be used instead of `/about/index.html`). The default
    #   value should be okay in most cases.
    #
    # * `enable_output_diff` (`Boolean`) - True when diffs should be generated
    #   for the compiled content of this site; false otherwise.
    #
    # The list of data sources consists of hashes with the following keys:
    #
    # * `:type` (`String`) - The type of data source, i.e. its identifier.
    #
    # * `:items_root` (`String`) - The prefix that should be given to all
    #   items returned by the {#items} method (comparable to mount points
    #   for filesystems in Unix-ish OSes).
    #
    # * `:layouts_root` (`String`) - The prefix that should be given to all
    #   layouts returned by the {#layouts} method (comparable to mount
    #   points for filesystems in Unix-ish OSes).
    #
    # * `:config` (`Hash`) - A hash containing the configuration for this data
    #   source. nanoc itself does not use this hash. This is especially
    #   useful for online data sources; for example, a Twitter data source
    #   would need the username of the account from which to fetch tweets.
    #
    # @return [Hash] The site configuration
    def config
      @config
    end

    # Fills each item's parent reference and children array with the
    # appropriate items. It is probably not necessary to call this method
    # manually; it will be called when appropriate.
    #
    # @return [void]
    def setup_child_parent_links
      teardown_child_parent_links

      item_map = {}
      @items.each do |item|
        next if item.identifier !~ /\/\z/
        item_map[item.identifier.to_s] = item
      end

      @items.each do |item|
        parent_id_end = item.identifier.to_s.rindex('/', -2)
        next unless parent_id_end

        parent_id = item.identifier.to_s[0..parent_id_end]
        parent = item_map[parent_id]
        next unless parent

        item.parent = parent
        parent.children << item
      end
    end

    # Removes all child-parent links.
    #
    # @api private
    #
    # @return [void]
    def teardown_child_parent_links
      @items.each do |item|
        item.parent = nil
        item.children = []
      end
    end

    # Prevents all further modifications to itself, its items, its layouts etc.
    #
    # @return [void]
    def freeze
      config.__nanoc_freeze_recursively
      items.each(&:freeze)
      layouts.each(&:freeze)
      code_snippets.each(&:freeze)
    end

    # Loads the site data. It is not necessary to call this method explicitly;
    # it will be called when it is necessary.
    #
    # @api private
    #
    # @return [void]
    def load
      return if @loaded || @loading
      @loading = true

      # Load all data
      load_code_snippets
      with_datasources do
        load_items
        load_layouts
      end
      setup_child_parent_links

      # Ensure unique
      ensure_identifier_uniqueness(@items, 'item')
      ensure_identifier_uniqueness(@layouts, 'layout')

      # Load compiler too
      # FIXME: this should not be necessary
      compiler.load

      @loaded = true
    rescue => e
      unload
      raise e
    ensure
      @loading = false
    end

    # Undoes the effects of {#load}. Used when {#load} raises an exception.
    #
    # @api private
    def unload
      return if @unloading
      @unloading = true

      @items_loaded = false
      @items = []
      @layouts_loaded = false
      @layouts = []
      @code_snippets_loaded = false
      @code_snippets = []

      compiler.unload

      @loaded = false
      @unloading = false
    end

    # @return [Boolean] true if the current working directory is a nanoc site, false otherwise
    #
    # @api private
    def self.cwd_is_nanoc_site?
      !config_filename_for_cwd.nil?
    end

    # @return [String] filename of the nanoc config file in the current working directory, or nil if there is none
    #
    # @api private
    def self.config_filename_for_cwd
      filenames = %w( nanoc.yaml config.yaml )
      filenames.find { |f| File.file?(f) }
    end

    private

    # Executes the given block, making sure that the datasources are
    # available for the duration of the block
    def with_datasources(&_block)
      data_sources.each(&:use)
      yield
    ensure
      data_sources.each(&:unuse)
    end

    # Loads this site’s code and executes it.
    def load_code_snippets
      @code_snippets_loaded ||= false
      return if @code_snippets_loaded
      @code_snippets_loaded = true

      # Get code snippets
      @code_snippets = []
      config[:lib_dirs].each do |lib|
        code_snippets = Dir["#{lib}/**/*.rb"].sort.map do |filename|
          Nanoc::Int::CodeSnippet.new(
            File.read(filename),
            filename
          )
        end
        @code_snippets.concat(code_snippets)
      end

      # Execute code snippets
      @code_snippets.each(&:load)
    end

    # Loads this site’s items, sets up item child-parent relationships and
    # builds each item's list of item representations.
    def load_items
      @items_loaded ||= false
      return if @items_loaded
      @items_loaded = true

      # Get items
      @items = Nanoc::Int::IdentifiableCollection.new(@config)
      data_sources.each do |ds|
        items_in_ds = ds.items
        items_in_ds.each do |i|
          i.identifier = i.identifier.prefix(ds.items_root)
          i.site = self
        end
        @items.concat(items_in_ds)
      end
    end

    # Loads this site’s layouts.
    def load_layouts
      @layouts_loaded ||= false
      return if @layouts_loaded
      @layouts_loaded = true

      # Get layouts
      @layouts = Nanoc::Int::IdentifiableCollection.new(@config)
      data_sources.each do |ds|
        layouts_in_ds = ds.layouts
        layouts_in_ds.each do |l|
          l.identifier = l.identifier.prefix(ds.layouts_root)
        end
        @layouts.concat(layouts_in_ds)
      end
    end

    # Loads a configuration file.
    def load_config(config_path)
      YAML.load_file(config_path).__nanoc_symbolize_keys_recursively
    end

    def apply_parent_config(config, config_paths = [])
      parent_config_file = config[:parent_config_file]
      if parent_config_file
        config.delete(:parent_config_file)
        config_path = File.absolute_path(parent_config_file, File.dirname(config_paths.last))
        unless File.file?(config_path)
          raise Nanoc::Int::Errors::GenericTrivial, "Could not find parent configuration file '#{parent_config_file}'"
        end
        if config_paths.include?(config_path)
          raise Nanoc::Int::Errors::GenericTrivial, "Cycle detected. Could not use parent configuration file '#{parent_config_file}'"
        end
        parent_config = load_config(config_path)
        apply_parent_config(parent_config, config_paths + [config_path]).merge(config)
      else
        config
      end
    end

    def ensure_identifier_uniqueness(objects, type)
      seen = Set.new
      objects.each do |obj|
        if seen.include?(obj.identifier)
          raise Nanoc::Int::Errors::DuplicateIdentifier.new(obj.identifier, type)
        end
        seen << obj.identifier
      end
    end

    # Builds the configuration hash based on the given argument. Also see
    # {#initialize} for details.
    def build_config(dir_or_config_hash)
      if dir_or_config_hash.is_a? String
        # Check whether it is supported
        if dir_or_config_hash != '.'
          warn 'WARNING: Calling Nanoc::Int::Site.new with a directory that is not the current working directory is not supported. It is recommended to change the directory before calling Nanoc::Int::Site.new. For example, instead of Nanoc::Int::Site.new(\'abc\'), use Dir.chdir(\'abc\') { Nanoc::Int::Site.new(\'.\') }.'
        end

        # Read config from nanoc.yaml/config.yaml in given dir
        config_path = Dir.chdir(dir_or_config_hash) do
          filename = self.class.config_filename_for_cwd
          if filename.nil?
            raise Nanoc::Int::Errors::GenericTrivial, 'Could not find nanoc.yaml or config.yaml in the current working directory'
          end
          File.absolute_path(filename, dir_or_config_hash)
        end

        @config = apply_parent_config(load_config(config_path), [config_path])
      else
        # Use passed config hash
        @config = apply_parent_config(dir_or_config_hash.__nanoc_symbolize_keys_recursively)
      end

      # Merge config with default config
      @config = DEFAULT_CONFIG.merge(@config)

      # Merge data sources with default data source config
      @config[:data_sources] = @config[:data_sources].map { |ds| DEFAULT_DATA_SOURCE_CONFIG.merge(ds) }

      # Convert to proper configuration
      @config = Nanoc::Int::Configuration.new(@config)
    end
  end
end
