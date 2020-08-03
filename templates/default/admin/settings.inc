<?php
    if(!empty($args['conf_change_type'])) {
        $conf  = $conf_obj->get($args['conf_change_type']);
        if($args['conf_change_type'] == 'users' ) {
            $real_conf = $conf;
            $conf = $real_conf[$args['name']];
        }
        $model = $conf_obj->get_config_model($args['conf_change_type']);
        $saved = false;
        foreach( $model as $key => $item ) {
            if(!empty($args[$key])) {
                if($key == 'password') {
                    # Hash it, save to correct param
                    $conf['auth_hash'] = password_hash( $args[$key], PASSWORD_DEFAULT );
                } else {
                    $conf[$key] = $args[$key];
                }
            }
        }
        if($args['conf_change_type'] == 'users' ) {
            unset($conf['name']);
            $real_conf[$args['name']] = $conf;
            $conf = $real_conf;
        }
        $conf_obj->set($args['conf_change_type'], $conf);
        $saved = $conf_obj->save($args['conf_change_type']);
        if($saved) {
            echo "<p>Successfully saved $saved bytes to " . $conf_obj->get_conf_dir() . '/' . $args['conf_change_type'] . ".json</p>";
        } else {
            echo '<p style="color:red;">Failed to save to ' . $conf_obj->get_conf_dir() . '/' . $args['conf_change_type'] . '.json!</p>';
        }
    }
?>
<p class="title">
 General settings:
</p>
<hr />
<form id="mainConfig" method="post" action="index.php">
    <input type="hidden" name="conf_change_type" value="main" />
    <table>
    <?php
        $conf  = $conf_obj->get('main');
        $model = $conf_obj->get_config_model('main');
        $line = '';

        foreach ( $model as $key => $item ) {
            $line .= '<tr>';
            $line .= '<td><label for="' . $key . '">' . $item['label'] . '</label></td>';
            if($item['form_field'] == 'select') {
                $line .= '<td><select class="cooltext" name="' . $key . '" id="' . $key . '">';
                foreach ( $item['select_opts'] as $option ) {
                    $line .= '<option value="' . $option . '">' . $option . '</option>';
                }
                $line .= '</select></td>';
            } elseif($item['form_field'] == 'input') {
                $val = !empty($conf[$key]) ? $conf[$key] : '';
                $line .= '<td><input type="text" class="cooltext" name="' . $key . '" id="' . $key . '" placeholder="'.$item['default'].'" value="'.$val.'" />';
            }
            $line .= '</tr>';
        }
        echo "$line\n";
    ?>
    </table>
    <br />
    <input type="submit" class="coolbutton" value="Commit Changes" />
</form>
<hr />

<p class="title">
 User management:
</p>
<hr />
<form id="userConfig" method="post" action="index.php">
    <input type="hidden" name="conf_change_type" value="users" />
    <?php
        $conf  = $conf_obj->get('users');
        $model = $conf_obj->get_config_model('users');
        $line = '';
        foreach ( $conf as $user => $data ) {
            $line .= "<table class='manageUserEntry'><tr><td><em>Manage user '$user'</em></td>";
            $line .= "<td style='text-align: right;'><label for='delete_$user'>Delete user?</label>";
            $line .= "<input id='delete_$user' type='checkbox' />";
            $line .= "</td></tr>";
            foreach ( $model as $key => $item ) {
                $line .= '<tr><td><label for="' . $key . '">' . $item['label'] . '</label></td>';
                $val = "";
                if( array_key_exists( $key, $data ) ) {
                    $val = $data[$key];
                } else if( array_key_exists( 'masks', $item ) && $item['masks'] == 'parent' ) {
                    $val = $user;
                }
                $line .= '<td><input class="cooltext" name="' . $key . '" id="' . $key . '" type="' . $item['field_type'] . '" placeholder="' . $item['placeholder'] . '" value="' . $val . '" /></td></tr>';
            }
            $line .= '</table>';
        }
        echo "$line\n";
    ?>
    <br />
    <input type="submit" class="coolbutton" value="Commit Changes" />
</form>
<br />
<p class="title">
 Add User:
</p>
<form id="addUser" method="post" action="index.php">
    <input type="hidden" name="conf_change_type" value="user" />
    <table>
    <?php
        $line = '';
        foreach ( $model as $key => $item ) {
            $line .= '<td><label for="' . $key . '">' . $item['label'] . '</label></td>';
            $line .= '<td><input class="cooltext" name="' . $key . '" id="' . $key . '" type="' . $item['field_type'] . '" placeholder="' . $item['placeholder'] . '" value="" /></td></tr>';
        }
        echo "$line\n";
    ?>
    </table>
    <br />
    <input type="submit" class="coolbutton" value="Commit Changes" />
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
