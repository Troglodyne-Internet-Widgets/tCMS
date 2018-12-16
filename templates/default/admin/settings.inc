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

        # For now there's no use to the 'form_field' setting, as main only uses select, user only inputs
        foreach ( $model as $key => $item ) {
            $line .= '<tr>';
            $line .= '<td><label for="' . $key . '">' . $item['label'] . '</label></td>';
            $line .= '<td><select name="' . $key . '" id="' . $key . '">';
            foreach ( $item['select_opts'] as $option ) {
                $line .= '<option value="' . $option . '">' . $option . '</option>';
            }
            $line .= '</select></td></tr>';
        }
        echo "$line\n";
    ?>
    </table>
    <br />
    <input type="submit" value="Commit Changes" />
</form>
<hr />

<p class="title">
 User management:
</p>
<hr />
<form id="userConfig" method="post" action="index.php">
    <input type="hidden" name="conf_change_type" value="user" />
    <table>
    <?php
        $conf  = $conf_obj->get('users');
        $model = $conf_obj->get_config_model('users');
        $line = '';
        foreach ( $conf as $user => $data ) {
            $line .= "<tr><td colspan=2><em>Manage user '$user'</em></td></tr>";
            foreach ( $model as $key => $item ) {
                $line .= '<tr><td><label for="' . $key . '">' . $item['label'] . '</label></td>';
                $val = "";
                if( array_key_exists( $key, $data ) ) {
                    $val = $data[$key];
                } else if( array_key_exists( 'masks', $item ) && $item['masks'] == 'parent' ) {
                    $val = $user;
                }
                $line .= '<td><input name="' . $key . '" id="' . $key . '" type="' . $item['field_type'] . '" placeholder="' . $item['placeholder'] . '" value="' . $val . '" /></td></tr>';
            }
        }
        echo "$line\n";
    ?>
    </table>
    <br />
    <input type="submit" value="Commit Changes" />
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
            $line .= '<td><input name="' . $key . '" id="' . $key . '" type="' . $item['field_type'] . '" placeholder="' . $item['placeholder'] . '" value="" /></td></tr>';
        }
        echo "$line\n";
    ?>
    </table>
    <br />
    <input type="submit" value="Commit Changes" />
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
