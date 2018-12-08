<p class="title">
 General settings:
</p>
<hr />
<form id="mainConfig" method="post" action="index.php">
    <?php
        $conf  = $conf_obj->get('main');
        $model = $conf_obj->get_config_model('main');
        $line = '<input type="hidden" name="conf_change_type" value="main"></input>';

        # For now there's no use to the 'form_field' setting, as main only uses select, user only inputs
        foreach ( $model as $key => $item ) {
            $line .= '<label for="' . $key . '">' . $item['label'] . '</label>';
            $line .= '<select name="' . $key '" id="' . $key . '">';
            foreach ( $item['select_opts'] as $option ) {
                $line .= '<option value="' . $option . '">' . $option . '</option>';
            }
            $line .= '</select>';
            echo "$line\n";
        }
    ?>
    <input type="submit" value="Commit Changes"></input>
</form>
<hr />

<p class="title">
 User management:
</p>
<hr />
<form id="userConfig" method="post" action="index.php">
    <?php
        $conf  = $conf_obj->get('user');
        $model = $conf_obj->get_config_model('user');
        $line = '<input type="hidden" name="conf_change_type" value="user"></input>';
        foreach ( $conf as $user => $data ) {
            foreach ( $model as $key => $item ) {
                $line .= '<label for="' . $key . '">' . $item['label'] . '</label>';
                $val = "";
                if( array_key_exists( $key, $data ) ) {

                } else if( array_key_exists( 'masks', $conf ) ) {
                    if( $conf['masks'] == 'parent' ) $val = 
                }
                $line .= '<input name="' . $key . '" id="' . $key . '" type="' . $item['field_type'] . '" placeholder="' . $item['placeholder'] . '" value="' . $val . '"></input><br />';
                echo "$line\n";
            }
        }
    ?>
    <input type="submit" value="Commit Changes"></input>
</form>
<p class="title">
 Add User:
</p>
<form id="addUser" method="post" action="index.php">
    <input type="hidden" name="conf_change_type" value="user"></input>
    <?php
        foreach ( $model as $key => $item ) {
            $line .= '<label for="' . $key . '">' . $item['label'] . '</label>';
            $line .= '<input name="' . $key . '" id="' . $key . '" type="' . $item['field_type'] . '" placeholder="' . $item['placeholder'] . '" value=""></input><br />';
            echo "$line\n";
        }
    ?>
    <input type="submit" value="Commit Changes"></input>
</form>
<hr />

<p class="title">
 Theme cloner:
</p>
<hr />
<p>
  Want to write your own theme?
  Clone a theme here then see the <a href="https://tcms.troglodyne.net/index.php?nav=5&post=fileshare/manual/Chapter 03-Customization.post" title="GET UR MIND RITE">styling guide</a>
  for information on how tCMS' templates, image sets and CSS work in the theming system.
</p>
INSERT FORM HERE
