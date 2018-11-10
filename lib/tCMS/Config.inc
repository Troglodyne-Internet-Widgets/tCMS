<?php
    class Config {

        private $confdir = null;
        private $basedir = null;
        private $homedir = null;
        private $conf = [
            'users' => [],
            'main'  => [],
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
    }
?>
