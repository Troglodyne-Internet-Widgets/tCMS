<?php
# Assume we're doing things interactively if we're passing in args
if( !empty( $argv[1] ) ) {
    exit(0);
}
class configure {
    # INPUT:
    #   Param 1: Config file to read. Throws on failure to read.
    #   Param 2: undef or ARRAY of keys you wanna fetch. undef/invalid assumes we'll be wanting all of them.
    # OUTPUT: ARRAY of the requested KEY => VALUE pairs.
    public function get_config_values() {
        return;
    }
    # INPUT:
    #   Param 1: Config file to write. Throws if it fails to write.
    #   Param 1: ARRAY of KEY => VALUE pairs you wanna set. Throws on invalid input.
    # OUTPUT: BOOL regarding success/failure.
    public function set_config_values() {
        return;
    }
}
?>
