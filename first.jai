#import "Compiler";
#import "Basic";
#import "Process";
#import "File";

#import "Metaprogram_Plugins";

OUTPUT_EXECUTABLE_NAME :: "example1";
OUTPUT_BUILD_DIR :: "./examples";
FILE_ENTRY_POINT :: "./examples/example1.jai";
FOR_CODEX :: true;

#run {

    set_build_options_dc(.{do_output = false}); //to avoid outputting this "first.jai"
    current_w := get_current_workspace();


    //
    // New Workspace (Target)
    //
    w := compiler_create_workspace("Target Programm");
    options := get_build_options(w);
    //we make the new workspace inherit the commands from current_w
    copy_commonly_propagated_fields(get_build_options(), *options); //If you dont do this, then -x64 doesnt work

    options.output_executable_name = OUTPUT_EXECUTABLE_NAME;
    options.output_path = OUTPUT_BUILD_DIR;

    //maximize debug info:
    //this is useful for stepping inside #asm blocks
    #if 0
    {
    options.shorten_filenames_in_error_messages = true;
    options.use_natvis_compatible_types = true;
    options.use_visual_studio_message_format = true;
    options.enable_bytecode_inliner = false;
    options.enable_bytecode_deduplication = false;
    options.interactive_bytecode_debugger = true;
    options.debug_for_expansions = true;
    //maybe comment out the following
    options.emit_debug_info = .CODEVIEW;
    }

    set_optimization(*options,.VERY_OPTIMIZED, false);
    // options.llvm_options.enable_slp_vectorization = .VERY_OPTIMIZED; delete this comment



    //
    //grab command lines
    //
    args := options.compile_time_command_line;
    #if FOR_CODEX
    {
        intercept_flags: Intercept_Flags;
        plugins: [..] *Metaprogram_Plugin;
        success, plugins_to_create :=  parse_plugin_arguments(args); //this fills an array with the plugins you pass with the + sign
        assert(success);
        init_plugins(plugins_to_create,*plugins, w);

        //initialize plugins
        assert(plugins.count == plugins_to_create.count);
        for p: plugins {
            c := *plugins_to_create[it_index];
            if p.init {
                success := p.init(p, c.options);
                assert(success);
            } else if c.options {
                log_error("Plugin '%' takes no options, but these options were given: %\n", c.name, c.options);
            }
        }

            //print their help
        for plugins {
            name := plugins_to_create[it_index].name;

            if it.log_help {
                log("---- Help for plugin '%': ----\n\n", name);
                it.log_help(it);
                log("\n");
            } else {
                log("---- Plugin '%' provides no help.\n", name);
            }
        }


    }



    set_build_options(options, w);

    #if FOR_CODEX then for plugins if it.before_intercept it.before_intercept(it, *intercept_flags);
    compiler_begin_intercept(w); //* not needed, but, for android and linking interceptions, it is needed. @july 2025: it is needed for plugins too!
    #if FOR_CODEX for plugins if it.add_source it.add_source(it);


    add_build_file(FILE_ENTRY_POINT,w); //compilin starts here on another thread process

    #if FOR_CODEX {
        while true {
            // We ask the compiler for the next message. If one is not available,
            // we will wait until it becomes available.
            message := compiler_wait_for_message();
            // Pass the message to all plugins.
            for plugins if it.message it.message(it, message);
            if message.kind == .COMPLETE break;
        }

    }
    // message_loop :: (w: Workspace) {
    //     while true {
    //         // We ask the compiler for the next message. If one is not available,
    //         // we will wait until it becomes available.
    //         message := compiler_wait_for_message();
    //         // Pass the message to all plugins.
    //         for plugins if it.message it.message(it, message);

    //         if message.kind == .COMPLETE break;
    //     }
    // }
    // message_loop(w); //this crap send messages to the plugins so you must call it, otherwise, plugins will not notice the code of the currently building workspace

    // And call compiler_end_intercept when done.
    compiler_end_intercept(w);

    #if FOR_CODEX then for plugins if it.finish   it.finish  (it);
    #if FOR_CODEX then for plugins if it.shutdown it.shutdown(it);
}