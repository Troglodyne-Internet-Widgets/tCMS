<?php
include "config/users.inc";
$badpost=false;
$errmsg = array();
if (isset($_POST["title"]) && $_POST["title"] != "") {
	if (!isset($_POST['URL']) || $_POST["URL"] == "") {
		$badpost = true;
		$errmsg[] = "<em style=\"color: red\">* No url provided.</em><br />";
	}
	$url=stripslashes($_POST["URL"]);
	//Error catching below
	if (!filter_var($url,FILTER_VALIDATE_URL)) {
		$badpost = true;
		$errmsg[] = "<em style=\"color: red;\">* \"$url\" is not a valid ASCII URL.</em><br />";
	}
	if (!empty($_POST["IMG"]) && !filter_var(stripslashes($_POST["IMG"]),FILTER_VALIDATE_URL)) {
    		$badpost = true;
		$errmsg[] = "<em style=\"color: red;\">* Image \"$url\" is not a valid ASCII URL.</em><br />";
  	}
  	if (!empty($_POST["AUD"]) && !filter_var(stripslashes($_POST["AUD"]),FILTER_VALIDATE_URL)) {
    		$badpost = true;
		$errmsg[] = "<em style=\"color: red;\">* Audio \"$url\" is not a valid ASCII URL.</em><br />";
  	}
  	if (!isset($_POST["comment"]) || $_POST["comment"] == '') {
    		$badpost = true;
		$errmsg[] = "<em style=\"color: red;\">* Comment is blank.</em><br />";
  	}
	if (!$badpost) { 
    		$title = stripslashes($_POST["title"]);
    		$image = stripslashes($_POST["IMG"]);
    		$audio = urlencode(stripslashes($_POST["AUD"]));
    		$audiosrc = stripslashes($_POST["AUD"]);
    		$comment = stripslashes($_POST["comment"]);
    		$news2write = "<h3 class=\"blogtitles\"><a href=\"".$url."\">".$title."</a>";
    		$news2write = $news2write."<a class=\"usericon ".$poster."\" href=\"index.php?nav=4\" title=\"Posted by ".$poster."\"></a>";
    		$news2write = $news2write."</h3>";
    		if ($image != "") {
      			$news2write = $news2write."<img class=\"mblogimg\" src=\"".$image."\" />";
    		}
    		if ($audio != "") {
      			$curlurl = "http://".$_SERVER["SERVER_NAME"]."/".$basedir.$microblog;
      			$ch = curl_init($cur_url);
      			curl_setopt($ch,CURLOPT_RETURNTRANSFER,true);
      			curl_setopt($ch,CURLOPT_HEADER,false);
      			$page_content = curl_exec($ch);
      			$matches = array();
      			preg_match('/audioplayer_[0-9]*/',$page_content,$matches);
      			$numfound = count($matches);
      			$audioinc = $numfound;
      			++$audioinc;
      			$news2write = $news2write."<p id=\"audioplayer_$audioinc\">Download Audio <a href=\"$audiosrc\">Here</a>.</p><script type=\"text/javascript\">AudioPlayer.embed(\"audioplayer_$audioinc\", {soundFile: \"$audio\"});</script><br />";
    		};
    		$news2write = $news2write.$comment."<hr />";
		$tdtime = new DateTime(null, new DateTimeZone($timezone));
    		$today = $tdtime->format('m.d.y');
    		$now = $tdtime->format('H:i:s');
    		$newsdir = $_SERVER["DOCUMENT_ROOT"].'/'.$basedir.$microblogdir;
    		@mkdir($newsdir.$today);
    		$fh = fopen($newsdir.$today."/".$now, 'w');
		if (!$fh) die("ERROR: couldn't write $newsdir$today/$now to $newsdir$today, check permissions");
		fwrite($fh,$news2write);
		fclose($fh);
	} else {
		print "Could not post due to errors:<br />";
		foreach ($errmsg as $err) {echo $err;}
		print "POST Variable Dump below:<br /><em style=\"color: red\">";
		var_dump($_POST);
		print "</em>";
	}
} elseif ($_POST["id"] != "") {
	if ($_POST["content"] == "") {
		$res = unlink($_POST["id"]);
		if (!$res) die("ERROR: couldn't delete ".$_POST['id'].", check permissions");
		echo "Deleted ".$_POST["id"]."<br />";
  } else {
		$fh = fopen($_POST["id"], 'w');
		if (!$fh) die("ERROR: couldn't write to ".$_POST['id'].", check permissions");
    fwrite($fh,stripslashes($_POST["content"]));
    fclose($fh);
		echo "Edited ".$_POST["id"]."<br />";
  }
}
?>
<div style="width: 100%; display: table;">
 <div style="width: 20%; display: table-cell;">
  <p class="title">Submissions:</p>
  <form id="Submissions" method="POST">
   Title<br /><input class="cooltext" type="text" name="title" />
   URL<br /><input class="cooltext" type="text" name="URL" />
   Image<br /><input class="cooltext" type="text" name="IMG" />
   Audio<br /><input class="cooltext" type="text" name="AUD" />
   Comments:<br /><textarea class="cooltext" name="comment">Potzrebie</textarea>
   <input class="coolbutton" type="submit" value="Publish" text="Publish" />
  </form>
 </div>
 <div id="stories">
  <?php
   $editable = 1;
   include $_SERVER["DOCUMENT_ROOT"].'/'.$basedir."sys/microblog.inc";
  ?>
 </div>
</div>
