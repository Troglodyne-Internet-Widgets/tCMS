<?php
class configure {
    # INPUT:
    #   Param 1: Config file to read. Throws on failure to read.
    #   Param 2: undef or ARRAY of keys you wanna fetch. undef/invalid assumes we'll be wanting all of them.
    # OUTPUT: ARRAY of the requested KEY => VALUE pairs.
    public static function get_config_values( $file = null, $desired_configs = null ) {
        if( !file_exists( $file ) ) throw new Exception( "$file doesn't exist." );
        $config = file_get_contents( $file );
        if( empty( $config ) )      throw new Exception( "$file couldn't be opened or is empty" );
        $config = json_decode( $config, true );
        if( empty( $config ) )      throw new Exception( "$file is not valid JSON" );
        if( !is_array( $config) )   throw new Exception( "Decoded $file's JSON string is not an array" );
        return $config;
    }
    # INPUT: ARRAY, preferably the one returned by get_config_values.
    # OUTPUT: ARRAY [ result => BOOL, reason => STRING ].
    public static function validate_config( $config = array() ) {
        #OK, so here we have to start making some 'assumptions' RE mutli-user environments (cPanel, etc.)
        $caller_info = posix_getpwuid();
        $basedir = $caller_info['dir'] . "/.tCMS";
        if( !file_exists( $basedir) || !is_dir( $basedir ) ) throw new Exception( "~/.tCMS doesn't exist." );
        $model_file = "$basedir/model.json";
        $model = self::get_config_values( $model_file );
        foreach ( $model as $key => $val ) {
            if( !array_key_exists( $key ) ) {
                return [ 'result' => 0, 'reason' => "Config file was missing required key '$key'" ];
            }
            # TODO check various directories here, make sure we can read/write as appropriate
        }
        return 1;
    }
    # INPUT:
    #   Param 1: Config file to write. Throws if it fails to write.
    #   Param 1: ARRAY of KEY => VALUE pairs you wanna set. Throws on invalid input.
    # OUTPUT: BOOL regarding success/failure.
    public static function set_config_values( $file = null, $desired_configs = null ) {
        return;
    }
}
?>
