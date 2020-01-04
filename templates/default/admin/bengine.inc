<script type="text/javascript">
//JS to load posts when you click on them to edit

  window.postsLoaded = {};

  function toggle(id) {
   var foo = document.getElementById(id);
   if (foo.style.display == 'block') {
     foo.style.display = 'none';
   } else {
     foo.style.display = 'block';
   }
 }

 function loadpost(fragment_url,element_id) {
   if (window.postsLoaded[element_id]) return;
   var element = document.getElementById(element_id);
   element.innerHTML = 'Loading ...';
   var xmlhttp = new XMLHttpRequest();
   xmlhttp.open("GET", fragment_url);
   xmlhttp.onreadystatechange = function() {
     if (xmlhttp.readyState == 4 && xmlhttp.status == 200) {
       element.innerHTML = xmlhttp.responseText;
       window.postsLoaded[element_id] = true;
     }
   }
   xmlhttp.send(null);
 }
</script>
<!--Post Creation DOM-->
<p class="posteditortitle">
 <a id="newpostlink" href="javascript:toggle('newpost')" title="Toggle hiding of New Post editor">
  Create New Post
 </a>
</p>
<div id="newpost" class="disabled">
 <form method="POST">
  <input type="hidden" name="id" value="CHANGEME" />
  Post Title:<br />
  <input id="newposttitle" name="title" class="cooltext" />
  Post Body: <span style="font-style: italic;">
   All HTML Tags accepted! Please see <a href="" title="Manual">here</a> regarding how to disable auto-formatting,
   or if additional help is required.
  </span>
  <textarea id="newposttext" name="content"></textarea><br />
  <input type="hidden" name="app" value="blog" />
  <input type="submit" name="mod" value="Create Post" class="coolbutton" />
 </form>
 <hr />
</div>
<?php
 /*Initialize vars, get directory contents*/
 $postincrementer = 0;
 $JSAIDS = "";
 $dir = $basedir.'/blog/';
 $postlisting = scandir($dir);
 rsort($postlisting, SORT_NUMERIC);
 /*Post Manipulation*/
 if (!empty($_POST["id"])) {
  /*Post Deletion*/
  if ($_POST["mod"] == "Delete Post") {
   $fh = unlink($_POST["id"]);
   if (!$fh) die("ERROR: couldn't delete ".$_POST['id'].", check permissions");
   echo "Deleted ".$_POST["id"]."<br />";
  /*Post Editing*/
  } elseif ($_POST["mod"] == "Commit Edit") {
   $fh = fopen($_POST["id"], 'w');
   if (!$fh) die("ERROR: couldn't write to ".$_POST['id'].", check permissions");
   fwrite($fh,stripslashes($_POST["content"]));
   fclose($fh);
   echo "Edited ".$_POST["id"]."<br />";
  /*Post Creation*/
  } elseif ($_POST["mod"] == "Create Post") {
    $pnum = intval(substr($postlisting[0],0,strpos($postlisting[0],'-'))) + 1;
    $id = $dir.$pnum."-".$_POST["title"].".post";
    /*echo $id."<br />";
    var_dump($postlisting[0]);
    var_dump($_POST);
    die("FOOBAR");*/
    $fh = fopen($id, 'w'); 
    if (!$fh) die("ERROR: Couldn't Write ".$id.", check permissions");
    fwrite($fh,stripslashes($_POST["content"]));
    fclose($fh);
    echo "Created ".$id."<br />";
  /*Catchall*/
  } else {
    die("Nothing to do");
  }
 }
  /*Spit out the posts into the DOM so that they can be edited/deleted*/
  $postlisting = scandir($dir);
  rsort($postlisting, SORT_NUMERIC);
  foreach ($postlisting as $key=>$val) {
    $id = basename($val);
    $posttitle = strstr($val,'.', true);
  if (!empty($posttitle)) {
   $postincrementer++;
   print "
    <p id=\"post".$postincrementer."\" class=\"posteditortitle\">
    <a id=\"link".$postincrementer."\" href=\"javascript:toggle('postcontent".$postincrementer."')\" title=\"Toggle hiding of post editor\">
    ".$posttitle."
    </a>
    </p>
    <div id=\"postcontent".$postincrementer."\" class=\"disabled\">
     <form method=\"POST\">
     <input type=\"hidden\" name=\"id\" value=\"$id\" />
      <textarea id=\"innerHTML".$postincrementer."\" name=\"content\" \">
      </textarea><br />
      <input type=\"submit\" name=\"mod\" value=\"Commit Edit\" class=\"coolbutton\">
      <input type=\"submit\" name=\"mod\" value=\"Delete Post\" class=\"coolbutton\">
     </form>
    </div>";
   $JSAIDS.="document.getElementById('link".$postincrementer."').addEventListener('click',function () {loadpost('".$val."','innerHTML".$postincrementer."',false);});\nwindow.postsLoaded['innerHTML".$postincrementer."'] = false;";
  }
 }
print "<script type=\"text/javascript\">\n
 window.onload = function() { $JSAIDS };\n
 </script>";
?>
