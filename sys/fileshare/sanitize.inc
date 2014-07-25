<?php 
$san=0;
//Forbid anything starting with / and anything with .. in it; also remote links
 $badguy = strpos($pwd, '/');
 $badguys = strstr($pwd,'..');

 $http = stristr($pwd,'http://');
 $https = stristr($pwd,'https://');
 $ftp = stristr($pwd, 'ftp://');
 $gop = stristr($pwd, 'gopher://');

 if ($badguy === 0) {
        include 'sys/fileshare/include/forbidden.inc';
        $san=1;
	return(0);
 }

 if ($badguys !== FALSE) {
        include 'sys/fileshare/include/forbidden.inc';
        $san=1;
	return(0);
 }

if ($http !== FALSE || $https !== FALSE || $ftp !== FALSE || $gop !== FALSE) {
        include 'sys/fileshare/include/external.inc';
        $san=1;
	return(0);
}

 //Check the list of other forbidden directories
 $blist = "sys/fileshare/include/blacklist";
 $channel = fopen($blist, "r");
 $contents = fread($channel, filesize($blist));
 $readable = preg_split('[/]', $contents);
 $countchocula = count($readable)-1;

 for ($a = 0; $a < $countchocula; $a++) {

        $patterns = '^'.$readable[$a];
        $foos = ereg($patterns, $pwd);

        if ($foos == 1) {
                include 'sys/fileshare/include/forbidden.inc';
		$san=1;
                return(0);
        }

 }
?>
