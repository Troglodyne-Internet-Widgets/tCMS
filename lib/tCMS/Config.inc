<?php
    class Config {

        private $confdir = null;
        private $basedir = null;
        private $homedir = null;
        private $conf = [
            'users' => [],
            'main'  => [],
        ];
        private $conf_model = [
            'users' => [
                'name'         => [ 'masks' => 'parent', 'label' => 'Username', 'placeholder' => 'AzureDiamond', 'form_field' => 'input', 'field_type' => 'text' ],
                'password'     => [ 'masks' => 'auth_hash', 'label' => 'Password', 'placeholder' => 'hunter2', 'form_field' => 'input', 'field_type' => 'password' ],
                'display_name' => [ 'label' => 'Display Name', 'placeholder' => "Your Name", 'default' => 'Anonymous', 'form_field' => 'input', 'field_type' => 'text' ],
                'avatar'       => [
                    'label'        => 'User Avatar',
                    'default'      => "R0lGODlhGAAYAMIAAAAAAIYGBp2dndHR0QAAAAAAAAAAAAAAACH+EUNyZWF0ZWQgd2l0aCBHSU1QACH5BAEKAAQALAAAAAAYABgAAANySBQc+jDGMOpwMj96OdYShYmg9okAAazsWqIDIMz0nGaiJbercIeXls1H+00utWTRhOS1Gp+JjLibcSpRyFTp8YR2TpGPBBETz4DAjlzeKmnsCNi5isuTboFdSy2y9g95XBcldDxZJYmKIIiLG4SOOBEJADs=",
                    'form_field'   => 'input',
                    'field_type'   => 'file',
                    'field_accept' => "image/*",
                    'placeholder'  => '',
                ],
             ],
            'main'  => [
                'home'  => [ 'label' => 'Default Home', 'default' => 'blog', 'form_field' => 'select', 'select_opts' => [ 'blog', 'microblog', 'fileshare' ] ],
                'theme' => [ 'label' => 'tCMS Theme', 'default' => 'default', 'form_field' => 'select', 'select_opts' => [ 'default' ] ],
                'microblogtitle' => [ 'label' => 'Microblog Title', 'default' => 'Microblog', 'form_field' => 'input', 'field_type' => 'text' ],
            ],
        ];

        // Get the configuration.
        public function get( $type='main' ) {
            if( !empty($this->conf[$type]) ) return $this->conf[$type];
            $confdir = $this->get_conf_dir();
            $tmp_conf = @json_decode( @file_get_contents("$confdir/$type.json"), true );
            if( !empty( $tmp_conf ) ) $this->conf[$type] = $tmp_conf;
            return $this->conf[$type];
        }

        public function get_base_dir() {
            if( !empty($this->basedir) ) return $this->basedir;
            $homedir = $this->get_home_dir();
            $this->basedir = ( file_exists( "$homedir/.tCMS_basedir") ? file_get_contents("$homedir/.tCMS_basedir") : "$homedir/.tCMS" );
            return $this->basedir;
        }

        public function set_base_dir($dir) {
            $this->basedir = $dir;
            return;
        }

        public function get_conf_dir() {
            if( !empty($this->confdir) ) return $this->confdir;
            $basedir = $this->get_base_dir();
            $this->confdir = "$basedir/conf";
            return $this->confdir;
        }

        public function get_home_dir() {
            if( !empty($this->homedir) ) return $this->homedir;
            $user_info = posix_getpwuid(posix_geteuid());
            $this->homedir = ( $user_info['dir'] ? $user_info['dir'] : '/var/www/' );
            return $this->homedir;
        }

        public function get_config_model($type='main') {
            return $this->conf_model[$type];
        }
    }
?>
