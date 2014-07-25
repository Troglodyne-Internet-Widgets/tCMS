<?php
$info =  getimagesize($post);
$ratio = round($info[0]/$info[1],2);
$parent = dirname($post);
if ($ratio == 1.00) {
 echo "<img alt=\"$post\" src=\"$post\" height=100% width=100% />";
} elseif ($ratio > 1.00) {
 $ht = (1.20-($ratio-1))*100;
 echo "<img alt=\"$post\" src=\"$post\" height=$ht% width=100% />";
} else {
 $wd = 100-(($ratio-1)*100);
 echo "<img alt=\"$post\" src=\"$post\" style=\"padding-left: auto; padding-right: auto;\" />";
}
echo "<a title=back href=\"index.php?nav=1&dir=$parent\"><img alt=back src=".$icondir."tsfolder-up.gif /></a>".basename($post)."&nbsp".$info[0]."x".$info[1]."<hr />";
?>
