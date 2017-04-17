defmodule Mix.Tasks.Gen do

  @moduledoc File.read!(Path.join([__DIR__, "../../../README.md"]))
  
  use Private
  
  use Mix.Task

  alias MixTaskGen.Assigns
  alias MixTemplates.Cache
  alias MixTaskGen.Options
  
  # @default_options %{
  #   into:  ".",
  #   force: false,
  # }

  @base_option_specs [
    into:  [ default: "."   ],
    force: [ default: false ],
  ]
  
  def run(args) do
    parse_command(args)
    |> run_command
  end

  private do

    #####################
    # Parameter parsing #
    #####################
    
    def parse_command(["--help"]),  do: :help
    def parse_command(["help"]),    do: :help
    def parse_command(["-h"]),      do: :help
    
    def parse_command(["--list"]),  do: :list
    def parse_command(["-l"]),      do: :list

    def parse_command([option = "-" <> _ | _rest]) do
      { :error, "unknown or misplaced option “#{option}”" }
    end 

    def parse_command([_template_name]) do
      { :error, "missing name of project" }
    end 

    def parse_command([_template_name, "-" <> _ | _rest]) do
      { :error, "missing name of project" }
    end 

    def parse_command([ project, name | rest ]) do
      { :new_project, project, name, rest }
    end

    def parse_command(other) do
      error("Unknown command: mix gen #{Enum.join(other, " ")}")
    end

    def options_from_args(args) do
      { switches, extra } =
        case OptionParser.parse(args, []) do
          { switches, [], extra } ->
            { switches, extra }
          { _switches, other, _extra } ->
            error("unknown option “#{Enum.join(other, " ")}”")
        end

      (extra ++ switches)
      |> Enum.map(&make_params_with_no_arg_true/1)
    end
    
    defp make_params_with_no_arg_true({param, nil}) do
      make_params_with_no_arg_true({param, true})
    end
    defp make_params_with_no_arg_true({"--" <> param, value}) do
      { String.to_atom(param), value }
    end
    defp make_params_with_no_arg_true(other), do: other
    

    ########################
    # mix gen project name #
    ########################
    
    def run_command( { :new_project, template_name, project_name, args }) do
      find_template(template_name)
      |> generate_project(template_name, project_name, args)
    end

    
    ################
    # mix gen list #
    ################

    def run_command(:list), do: list_local_templates()


    ################
    # mix gen help #
    ################

    def run_command(:help), do: usage()

    
    #########
    # other #
    #########

    def run_command({ :error, reason }), do: error(reason)


    ################################
    # Helpers for generate_project #
    ################################

    defp accumulate_specs(template) do
      if parent_name = template.based_on() do
        parent_module = find_template(parent_name)
        template.options() ++ accumulate_specs(parent_module)
      else
        template.options() ++ @base_option_specs
      end
    end
    
    defp build_options(template, args) do
      specs   = accumulate_specs(template)
      Options.from_args(args, specs)
    end
    

    defp generate_project(nil, template_name, _project_name, _args) do
      error("Can't find template “#{template_name}”")
    end
    
    defp generate_project(template_module, template_name, project_name, args) do
      normalized_args = options_from_args(args)
      options = build_options(template_module, normalized_args)

      generate_with_options(template_module, template_name, project_name, options)
    end

    defp generate_with_options(template_module, template_name, project_name, options) do
      options = 
        maybe_invoke_based_on(template_module.based_on(),
        template_name,
        project_name,
        options)

      assigns = global_assigns(options, template_module, project_name)
      create_output(assigns)
      template_module.clean_up(assigns)
    end

    
    defp global_assigns(options, template_module, project_name) do
      %{
        host_os:                 Assigns.os_type(),
        now:                     Assigns.date_time_values(),
        original_args:           options,
        
        project_name:            project_name,
        project_name_camel_case: Macro.camelize(project_name),
        target_dir:              options.into,
        in_umbrella?:            in_umbrella?(),

        target_subdir:           project_name,
        template_module:         template_module,
        template_name:           template_module.name(),

        elixir_version:          System.version(),
        erlang_version:          :erlang.system_info(:version),
        otp_release:             :erlang.system_info(:otp_release),

        force:                   options.force,
      }
      |> Map.merge(options)
    end

    
    defp find_template(name = <<".", _ :: binary>>) do
      find_local_template(name)
    end
    
    defp find_template(name = <<"/", _ :: binary>>) do
      find_local_template(name)
    end
    
    defp find_template(template_name) do
      case Cache.find(template_name) do
        nil ->
          error("Cannot find a template called “#{template_name}”")
          list_local_templates("\nHere are the available templates:")
          exit(:normal)
        module ->
          module
      end
    end
    
    defp find_local_template(dir) do
      MixTemplates.Cache.load_template_module(dir)
    end
    
    defp create_output(assigns) do
      case MixTemplates.generate(assigns.template_module, assigns) do
        { :error, reason } ->
          Mix.shell.info([ :red, "Error: ", :reset, reason ])
        :ok ->
          Mix.shell.info([ :green, "Successfully generated ",
                           :reset, assigns.project_name,
                           :green, " in ",
                           :reset, assigns.target_dir])
      end
          
    end


    defp maybe_invoke_based_on(nil, _, _, options) do
      options
    end
    
    defp maybe_invoke_based_on(based_on_name, template_name, project_name, options) do
      based_on_module = find_template(based_on_name)
      if !based_on_module do
        Mix.raise("""
        Cannot find template “#{based_on_name}” 
        This is needed by the template “#{template_name}”
        """)
      end
      generate_with_options(based_on_module, based_on_name, project_name, options)
      Map.put(options, :force, "based_on")
    end
    
    
    ###########
    # Utility #
    ###########

    defp error(message, extras \\ nil)
    defp error(message, extras) when is_list(extras) do
      error(message, extras |> Enum.map(&inspect/1) |> Enum.join(", "))
    end
    defp error(message, nil) do
      Mix.shell.info([ :red, "ERROR: ", :reset, message ])
    end
    defp error(message, extras) do
      Mix.shell.info([ :red, message, :reset, extras ])
    end

    defp usage() do
      IO.puts "USAGE:"
      list_local_templates()
      exit(:normal)
    end

    defp list_local_templates(title) do
      IO.puts("\n#{title}\n")
      list_local_templates()
    end
    
    defp list_local_templates() do
      Mix.Task.run("template", [])
    end

    # stolen from mix/tasks/new.ex. 
    defp in_umbrella? do
      apps = Path.dirname(File.cwd!)
      
      try do
        Mix.Project.in_project(:umbrella_check, "../..", fn _ ->
          path = Mix.Project.config[:apps_path]
          path && Path.expand(path) == apps
        end)
      catch
        _, _ -> false
      end
    end
    
  end

end
