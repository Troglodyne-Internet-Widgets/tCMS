<?php
  //TODO have include file here for string size validation function
  //Microblog Posting engine - also used to display a form for submitting stories
  if (!empty($_POST["title"])) {//First check for a title in your POST data. If so, assume we're posting something new
    $errors = array();//Create empty error array
    //Validation checks
    $url = stripslashes($_POST["URL"]);
    if (empty($_POST['URL'])) {$errors[] = "No url provided.";}
    else if (!filter_var($url,FILTER_VALIDATE_URL)) {$errors[] = '"'.$url.'" is not a valid ASCII URL.';}
    if (!empty($_POST["IMG"]) && !filter_var(stripslashes($_POST["IMG"]),FILTER_VALIDATE_URL)) {$errors[] = 'Image "'.$url.'" is not a valid ASCII URL.';}
    if (!empty($_POST["AUD"]) && !filter_var(stripslashes($_POST["AUD"]),FILTER_VALIDATE_URL)) {$errors[] = 'Audio "'.$url.'" is not a valid ASCII URL.';}
    if (empty($_POST["comment"]) && empty($_POST["IMG"]) && empty($_POST["AUD"])) {$errors[] = "Post content is blank, Please add a comment or media to the posting.";}
    //TODO Need to do extra validation here to prevent folks from doing something stupid like inserting executable code or large hex dumps of files
    if (!count($errors)) {//All POST Vars needed to construct a coherent posting are here, let's format our data and write this thing
      include_once("config/users.inc");//Import userland functions to figure out who's posting
      $postBody = array(
        "title"   => stripslashes($_POST["title"]),
        "url"     => $url,
        "image"   => stripslashes($_POST["IMG"]),
        "audio"   => stripslashes($_POST["AUD"]),
        "comment" => stripslashes($_POST["comment"]),
        "poster"  => $poster
      );
      $tdtime = new DateTime(null, new DateTimeZone($timezone));
      $today = $tdtime->format('m.d.y');
      $now = $tdtime->format('H:i:s');
      $newsdir = $_SERVER["DOCUMENT_ROOT"].'/'.$basedir.$microblogdir;
      @mkdir($newsdir.$today);
      $fh = fopen($newsdir.$today."/".$now, 'w');
      if (!$fh) die("ERROR: couldn't write $newsdir$today/$now to $newsdir$today, check permissions");
      fwrite($fh,json_encode($postBody));
      fclose($fh);
    } else {//Print errors at the top, since we didn't have what we needed from POST
      $message = 'Could not post due to errors:<br /><ul style="color: red; list-type: disc;">';
      foreach ($errors as $err) {$message .= "<li>$err</li>";}
      $message .= '</ul>POST Variable Dump below:<br /><em style="color: red; font-size: .75em;">'.print_r($_POST, true).'</em>';
      echo $message;
    }
  } elseif (!empty($_POST["id"])) {//If no title is supplied, let's see if we're editing/deleting a post.
    if (empty($_POST["content"])) {//BLANKING IN PROGRESS
      $res = unlink($_POST["id"]);
      if (!$res) die("ERROR: couldn't delete ".$_POST['id'].", check permissions");
      echo "Deleted ".$_POST["id"]."<br />";
    } else {//Attempt editing, first detecting whether content is json
      $fh = fopen($_POST["id"], 'w');
      if (!$fh) die("ERROR: couldn't write to ".$_POST['id'].", check permissions");
      if(is_null(json_decode($_POST["content"]))) {$content = stripslashes($_POST["content"]);}//Do some munging if it's just raw text
      else {$content = $_POST["content"];}//JSON should be formatted correctly already
      fwrite($fh,$content);//Just write the blob ,TODO validation
      fclose($fh);
      echo "Edited ".$_POST["id"]."<br />";
    }
  }
  //DOM below
?>
<div id="mbengine">
 <div id="submissions">
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
