<p class="title">
 <a title="RSS" href="sys/rss/blog.php" class="rss"></a>
 <?php
  echo $blogtitle;
 ?>
 <hr />
</p>
<?php

if ($_GET['post'] != "") {
    $post=urldecode($_GET['post']);
    $statz = stat($post);
    $uid = $statz['uid'];
    $udata = posix_getpwuid($uid);
    $user = $udata['name'];

    $date =  date("F d Y H:i:s", filemtime($post));

    if (stristr($post,'.') != ".post") {
        $title = basename($post);
    } else {
        $title = substr(strstr(basename($post),'-'),1,-5);
    }

    echo "<h3 class=\"blogtitles\"><a title=permalink href=\"index.php?nav=3&post=".urlencode($post)."\">$title</a></h3>\n";
    echo "<em class=\"blogdetail\">Last modified on $date UTC by $user</em><hr />\n\n";
    include "$post";
    echo "\n<hr /><a style=\"textalign: center;\" href=\"".$_SERVER["PHP_SELF"]."?nav=3\">Back to Blog</a>";
} else {

$offset=0;
if ($_GET['index'] != "" && !is_int($_GET['index'])) {
	$offset = 10*$_GET['index'];
}


	//slurp up the files
	$files = glob("blog/*.post");
	$guid = count($files);

	//sort by filename
	
	//initialize an array to house sort results
	$files2 = array();
	$files2 = array_pad($files2,$guid,0);

	for ($i=0; $i<$guid; $i++) {
		$j = explode('-',basename($files[$i]));
		$j = $j[0];
		$j = (int)$j;
		$j--;
		$files2[$j] = $files[$i];
	}

	$slen = count($files2)-1;
	$ctr=0;
	$older=0;

	for ($i=$slen-$offset; $i>-1; $i--) {
		$shitpost=$files2[$i];

		//using a counter here to know when to stop, since I don't know how many posts there will be
		if ($ctr > 9) {
			$older=1;
			break;
		}
		$ctr++;

		$statz = stat($shitpost);
		$uid = $statz['uid'];
		$udata = posix_getpwuid($uid);
		$user = $udata['name'];

		$date =  date("F d Y H:i:s", filemtime($shitpost));

		$title = substr(strstr(basename($shitpost),'-'),1,-5);

		echo "<h3 class=\"blogtitles\"><a title=permalink href=\"".$_SERVER["PHP_SELF"]."?nav=3&post=".urlencode($shitpost)."\">$title</a></h3>\n";
		echo "<em class=\"blogdetail\">Last modified on $date UTC by $user</em><br />\n";
		include $shitpost;
		echo "<hr />";
	};

echo "<table width=\"100%\"><tr><td>";
if ($older) {
	$offset=$_GET['index']+1;
	echo "<a href=\"".$_SERVER["PHP_SELF"]."?nav=3&index=$offset\">Older Posts</a>";
}
echo "</td><td style=\"text-align: right;\">";
if ($_GET['index'] != "") {
	$offset=$_GET['index']-1;
	if ($offset == 0) {
		echo "<a href=\"".$_SERVER["PHP_SELF"]."?nav=3\">Newer Posts</a>";
	} else {
		echo "<a href=\"".$_SERVER["PHP_SELF"]."?nav=3&index=$offset\">Newer Posts</a>";
	}
}
echo "</td></tr></table>\n";
}
?>
