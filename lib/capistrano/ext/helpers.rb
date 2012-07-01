require 'digest/sha1'
require 'highline'

Capistrano::Configuration.instance(:must_exist).load do
  # Taken from the capistrano code.
  def _cset(name, *args, &block)
    unless exists?(name)
      set(name, *args, &block)
    end
  end

  # Taken from Stackoverflow
  # http://stackoverflow.com/questions/1661586/how-can-you-check-to-see-if-a-file-exists-on-the-remote-server-in-capistrano
  def remote_file_exists?(full_path, options = {})
    options[:via] = :sudo if options.delete(:use_sudo)
    'true' ==  capture("test -e #{full_path}; if [ $? -eq 0 ]; then echo true; fi", options).strip
  end

  def link_file(source_file, destination_file)
    if remote_file_exists?(source_file)
      begin
        run "#{try_sudo} ln -nsf #{source_file} #{destination_file}"
      rescue Capistrano::CommandError
        abort "Unable to create a link for '#{source_file}' at '#{destination_file}'"
      end
    end
  end

  def clean_folder(folder)
    find_params = ["-name '._*'", "-name '*~'", "-name '*.tmp'", "-name '*.bak'"]
    commands = find_params.inject '' do |commands, find_param|
      commands << "#{try_sudo} find #{folder} #{find_param} -exec rm -f {} ';';"
    end

    run commands
  end

  # Deeply link files from a folder to another
  def deep_link(from, to)
    script = <<-END
      exhaustive_list_of_files_to_link() {
        files="";

        for file in `ls -A1 ${1}`; do
          dest_file="${2}/${file}";
          file="${1}/${file}";
          if [ -e "${dest_file}" ]; then
            files="${files} `exhaustive_list_of_files_to_link ${file} ${dest_file}`";
          else
            files="${files} ${file}:${dest_file}";
          fi;
        done;
        echo "${files}";
      };

      files=`exhaustive_list_of_files_to_link '#{from}' '#{to}'`;
      for file in ${files}; do
        ln -s "`echo "${file}" | cut -d: -f1`" \
          "`echo "${file}" | cut -d: -f2`";
      done;
    END

    run script
  end

  # Link all items
  def link_items(from, to)
    script = <<-END
      symlink_all_shared_items() {
        for file in `ls -A1 ${1}`; do
          dest_file="${2}/`echo "${file}" | tr ',' '/'`";
          file="${1}/${file}";
          mkdir -p "`dirname "${dest_file}"`";
          ln -nsf "${file}" "${dest_file}";
        done;
      };

      symlink_all_shared_items '#{from}' '#{to}';
    END

    run script
  end

  def gen_pass( len = 8 )
      chars = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
      newpass = ""
      1.upto(len) { |i| newpass << chars[rand(chars.size-1)] }
      return newpass
  end

  def ask(what, options = {})
    options[:validate] = /(y(es)?)|(no?)|(a(bort)?|\n)/i unless options.key?(:validate)
    options[:echo] = true if options[:echo].nil?

    ui = HighLine.new
    ui.ask("#{what}?  ") do |q|
      q.overwrite = false
      q.default = options[:default]
      q.validate = options[:validate]
      q.responses[:not_valid] = what
      q.echo = "*" unless options[:echo]
    end
  end

  # Read a remote file
  def read(file, options = {})
    options[:via] = :sudo if options.delete(:use_sudo)
    capture("cat #{file}", options)
  end

  def write(content, path = nil, options = {})
    random_file = random_tmp_file(path)
    put content, random_file
    return random_file if path.nil?

    commands = <<-CMD
      cp #{random_file} #{path}; \
      rm -f #{random_file}
    CMD

    begin
      if options[:use_sudo]
        sudo commands
      else
        run commands
      end
    rescue Capistrano::CommandError
      logger.important "Error uploading the file #{path}"
      abort "Error uploading the file #{path}"
    end
  end

  def generate_random_file_name(data = nil)
    if data
      "#{fetch :application}_#{Time.now.strftime('%d-%m-%Y_%H-%M-%S-%L')}_#{Digest::SHA1.hexdigest data}"
    else
      "#{fetch :application}_#{Time.now.strftime('%d-%m-%Y_%H-%M-%S-%L')}"
    end
  end

  def random_tmp_file(data = nil)
    "/tmp/#{generate_random_file_name data}"
  end

  # ask_for_confirmation(what)
  # This function asks the user for confirmation (confirm running the task)
  # If the user answers no, then the task won't be executed.
  def ask_for_confirmation(what, options = {})
    unless exists?(:force) and fetch(:force) == true
      # Ask for a confirmation
      response = ask(what, options)
      if response =~ /(no?)|(a(bort)?|\n)/i
        abort "Canceled by the user."
      end
    end
  end

  def arguments
    index = ARGV.index(main_task) + 1
    abort 'Too many arguments' if ARGV.size - 1 > index
    abort 'Too few arguments'  if ARGV.size - 1 < index
    task ARGV[index] { } # Defines a task by the argument name
    ARGV[index]
  end

  def exists_and_not_empty?(key)
    exists?(key) && fetch(key).present?
  end

  def main_task
    task_call_frames.find { |t| ARGV.include? t.task.fully_qualified_name }.task.fully_qualified_name
  end

  def find_and_execute_db_task(task)
    db_server_app = fetch :db_server_app

    case db_server_app.to_sym
    when :mysql
      find_and_execute_task "db:mysql:#{task}"
    else
      abort "The database server #{db_server_app} is not supported"
    end
  end

  def format_credentials(credentials)
    <<-EOS.gsub(/^\s+/, '')
      adapter: #{fetch :db_server_app}
      hostname: #{credentials[:hostname]}
      port: #{credentials[:port]}
      username: #{credentials[:username]}
      password: #{credentials[:password]}
    EOS
  end

  def match_from_content(contents, part)
    contents.
      match(fetch "db_credentials_#{part}_regex".to_sym).
      try(:[], fetch("db_credentials_#{part}_regex_match".to_sym)).
      try(:chomp)
  end

end
