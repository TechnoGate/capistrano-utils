Capistrano::Configuration.instance(:must_exist).load do
  set :repository,
    fetch(:project_repository, `git remote show -n origin | grep 'URL' | awk '{print $3}' | head -n 1`.strip)
end
