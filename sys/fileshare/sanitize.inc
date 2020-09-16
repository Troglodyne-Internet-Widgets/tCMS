<?php 
if( !empty($pwd) ) {
    //Forbid anything starting with / and anything with .. in it; also protocol links (://)
    $forbidden = preg_match( "/|..|://", $pwd );
    if ( $forbidden ) {
        include 'sys/fileshare/include/forbidden.inc';
        die();	
    }

    //Check the list of other forbidden directories
    $blacklist = json_decode( file_get_contents("sys/fileshare/include/blacklist.json"), true );
    if( !empty( $blacklist ) ) {
    foreach ( $blacklist as $blacklisted ) {
        if ( preg_match('^' . $blacklisted, $pwd) ) {
            include 'sys/fileshare/include/forbidden.inc';
            die();
        }
    }
}
?>
