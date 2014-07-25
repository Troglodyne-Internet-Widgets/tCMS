<!--Scripts below allow audio player JS to show up with fancy little player-->
<script type="text/javascript" src="sys/fileshare/include/audio-player.js"></script>
<script type="text/javascript">
	AudioPlayer.setup("sys/fileshare/include/player.swf", {
	width: 290,
	transparentpagebg: "yes",
	});
</script>
<?php
  if ($editable) {
    echo "
      <script type=\"text/javascript\">
        function switchMenu(obj) {
          var el = document.getElementById(obj);
          if ( el.style.display != 'none' ) {
            el.style.display = 'none';
          }
          else {
            el.style.display = '';
	  }
        }
      </script>\n";
  }
  echo '<p class="title"><a title="RSS" class="rss" href="/'.$basedir.$rssdir.'microblog.php"></a>';
  echo $microblogtitle;
  //Set important times - $tdtime is today's date, $oldtime is the oldest known date a tCMS install had nuze for - defaults to today then searches microblog dir for entries to set date
  $tdtime = new DateTime(null, new DateTimeZone($timezone));
  $oldtime = clone $tdtime;
  //limit results of directory read to first entry
  function &oldtimer($timezone, $basedir, $microblogdir) {
    if ($handle = opendir($_SERVER["DOCUMENT_ROOT"].'/'.$basedir.$microblogdir)) {
      while (false !== ($entry = readdir($handle))) {
        if ($entry != "." && $entry != "..") {
          $oldtime = DateTime::createFromFormat('m.d.y', $entry, new DateTimeZone ($timezone));
          closedir($handle);
          return($oldtime);
        }
      }
    }
  };
  $oldtime = &oldtimer($timezone, $basedir, $microblogdir);
  $oldtime->sub(new DateInterval('P1D'));
  //$today and $tmrw refer to times relative to what is passed by GET params - $today is the date requested by GET, $tmrw is bool designating whether $today is something other than $tdtime 
  //error indicates whether you supplied a bogus GET param for date.
  $tmrw = 0;
  $error = 0;
  $today = clone $tdtime;
  if ($_GET["date"] != "") {
    $today = DateTime::createFromFormat('m.d.y', $_GET["date"], new DateTimeZone ($timezone));
    //Catch bogus input, set $tmwr to TRUE if $today was set to something other than today's date
    if (!filter_var($_GET["date"],FILTER_VALIDATE_REGEXP,array('options' => array('regexp' => "/^(0[1-9]|1[012])[.](0[1-9]|[12][0-9]|3[01])[.]\d\d/")))) {
      echo "</p>That's a funny looking date you provided there, mister.\n";
      $error=1;
    }
    else if ($today > $tdtime) { //catch if day supplied by GET is IN THE FUTURE
      echo "</p>Welcome to the future<br /><img style=\"max-width:100%; padding-left: auto; padding-right: auto;\" src=\"http://gunshowcomic.com/comics/20090930.png\" />\n";
      $error=1;
    }   
    else if ($today < $tdtime) {
      $tmrw = 1;
    }
  }
  //Catch if day in question has no news - If not, display day before (or before that if still no news. $oldtime used here to tell when to stop looping back)
  if (!$error) {
    while (empty($todaysnews)) {
     $yesterday = clone $today;
     $yesterday->sub(new DateInterval('P1D'));
     //Detect if We're at the end of postings
     if ($yesterday < $oldtime) {
        echo " (".$today->format('m.d.y')."):</p><hr />";
        echo "For me, it was a beginning, but for you it is the end of the road.<br /><hr />\n";
        if ($oldtime != $tdtime) {
          $tomorrow = clone $oldtime;
          $tomorrow->add(new DateInterval('P1D'));
	  $tomorrow = $tomorrow->format('m.d.y');
        }
        $todaysnews = "end";
      }
      if ($todaysnews != "end") {
        //Get news from directory if any exists for that day
        $todaysnews = glob($_SERVER["DOCUMENT_ROOT"].'/'.$basedir.$microblogdir.$today->format('m.d.y')."/*");
        //Set display date for today's news, set $today to be yesterday in order to get while loop to recurse correctly
        $realtime = $today->format('m.d.y');
        $today = clone $yesterday;
        //Finish by setting times for Yesterday and Tomorrow so that they can be used in links below
        $tomorrow = clone $yesterday;
        $tomorrow->add(new DateInterval('P2D'));
        $tomorrow = $tomorrow->format('m.d.y');
        $yesterday = $yesterday->format('m.d.y');
      }
    }
    if ($todaysnews != "end") {
      echo " (".$realtime."):</p><hr />\n";
      foreach ($todaysnews as $i) {
        $fh = fopen($i,'r');
        $fc = fread($fh,10000); //If a microblog item is more than 1kb, you are doing something wrong.
        fclose($fh);
        echo $fc;
        if ($editable) {
          $id=basename($i);
	  echo "
            <a style=\"display: inline-block;\" onclick=\"switchMenu('$id');\">[Edit]</a>
            <div style=\"display: none;\" id=\"$id\">
             <form style=\"display: inline\" method=\"POST\">
              <input type=\"hidden\" name=\"id\" value=\"$i\" />
              <input type='hidden' name='action' value='Edit' />
              <textarea class=\"mbedit_text\" name=\"content\">$fc</textarea>
              <input class=\"coolbutton mbedit_button\" type=\"submit\" Value=\"Edit\" />
             </form>
             <form style=\"display: inline\" method=\"POST\">
              <input type=\"hidden\" name=\"id\" value=\"$i\" />
              <input type='hidden' name='action' value='Delete' />
              <input class=\"coolbutton mbedit_button\" type=\"submit\" value=\"Delete\" />
             </form>
            </div>
            <hr class=\"clear\" />";
        }
        echo "\n";
      }
      echo "<a style=\"float: left;\" title=\"skips empty days\" href=\"".$_SERVER["PHP_SELF"]."?nav=2&date=".$yesterday."\">Yesterday's News</a>\n";
    }
    if ($tmrw) {
      echo "<a style=\"float: right;\" href=\"".$_SERVER["PHP_SELF"]."?nav=2&date=".$tomorrow."\">Tomorrow's News</a>\n";
    }
  } else {
    //Do nothing - errors thrown above
  }
?>
