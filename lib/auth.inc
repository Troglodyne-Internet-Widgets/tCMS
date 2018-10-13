<?php
    class auth {

        public function __construct() {
            ini_set( "session.cookie_httponly", true );
            ini_set( "session.cookie_secure",   true );
            return;
        }

        public function ensure_auth( $redirect=true ) {
            // Force HTTPS
            if( empty( $_SERVER["HTTPS"] ) ) {
                http_response_code(301);
                header("Location: https://" . $_SERVER["SERVER_NAME"] . "/" . $_SERVER["REQUEST_URI"]);
                die();
            }
            // Check on the session
            $session_status = session_status();
            // Way to be consistent, PHP
            if( $session_status !== PHP_SESSION_ACTIVE || $session_status !== 2 ) session_start(); # Will re-use the existing session and jam the deets into the $_SESSION global
            $session_status = session_status();
            if( empty( $_SESSION )
                || ( $session_status !== PHP_SESSION_ACTIVE || $session_status !== 2 )
                || ( isset( $_SESSION['LAST_ACTIVITY'] ) && ( time() - $_SESSION['LAST_ACTIVITY'] > 3600 ) )
                || $_SESSION['REMOTE_ADDR'] !== $_SERVER['REMOTE_ADDR'] ) {
                $to = ( $_GET['app'] ) ? "&to=" . $_GET['app'] : "";
                auth::invalidate_auth( $redirect, $to );
            }
            $_SESSION['LAST_ACTIVITY'] = time();
            return session_id();
        }

        public function invalidate_auth( $redirect=true, $to="" ) { 
            // need to invalidate the session here, though we may not have loaded it yet, so do that first.
            $session_status = session_status();
            if( $session_status !== PHP_SESSION_ACTIVE || $session_status !== 2 ) session_start();
            $session_status = session_status();
            $session_id = session_id();
            if( $session_status === PHP_SESSION_ACTIVE || $session_status === 2 ) { 
                session_unset();
                session_destroy();
            }   
            setcookie('PHPSESSID'); //Otherwise it'll stick around. I don't wanna reuse these.
            if( $redirect ) {
                http_response_code(302);
                header( "Location: https://" . $_SERVER["SERVER_NAME"] . "/sys/admin/index.php?app=login$to" );
            } else {
                http_response_code(401);
                header('Content-Type: application/json');
                echo json_encode( [ 'code' => '401', 'message' => 'Unauthorized' ] );
            }   
            die();
        }   

        public function do_auth($user=null, $pass=null) {
            if( empty($user) || empty($pass) ) {
                return array( 'err' => 1, 'msg' => "No Credentials provided yet" );
            }
                        if( empty( ini_get('session.entropy_file') ) && version_compare(PHP_VERSION, "7.1.0") === -1 ) {
                ini_set('session.entropy_file', '/dev/urandom');
                ini_set('session.entropy_length', '32');
            }
            // Check it
            $user_info = posix_getpwuid(posix_geteuid());
            $homedir = ( $user_info['dir'] ? $user_info['dir'] : '/var/www/' );
            $confdir = ( file_exists( "$homedir/.tCMS_basedir") ? file_get_contents("$homedir/.tCMS_basedir") . "/conf" : "$homedir/.tCMS/conf" );
            $conf = file_get_contents("$confdir/users.json");
            if( $conf === false ) return [ 'err' => 1, "msg" => "Login Failed: Configuration missing" ];
            $conf = json_decode( $conf, 1 );
            if( $conf === null ) return [ 'err' => 1, "msg" => "Login Failed: Configuration malformed" ];
            if( empty($conf[$user]) || empty($conf[$user]['auth_hash']) || !password_verify( $pass, $conf[$user]['auth_hash'] ) ) return [ 'err' => 1, 'msg' => "Login Failed" ];

            // Gotta have a touch of eval
            $session_started = @session_start();
            if( empty($_SESSION) ) {
                @session_destroy();
                session_id(uniqid("tCMS-"));
                session_start();
            }
            $session_state   = session_status();
            $session_id      = session_id();
            if( empty($session_started) || empty( $session_state ) || $session_state !== PHP_SESSION_ACTIVE || empty( $session_id ) ) {
                return [ 'err' => 1, 'msg' => 'Failed to generate valid PHP Session' ];
            }
            $_SESSION['LAST_ACTIVITY'] = time(); //Timeout helper
            $_SESSION['REMOTE_ADDR'] = $_SERVER['REMOTE_ADDR']; // Hijacking prevention helper
            return [ 'success' => 1 ];
        }

        public static function process_token( $api_token=null ) {
            if( session_status() !== PHP_SESSION_ACTIVE ) session_start();
            if( empty( $api_token ) ) return 0;
            $key = file_get_contents( "/var/cpanel/qa/.userdata_cache/global/session_keys/" . session_id() );
            if( empty( $key ) ) return 0;
            $api_token = base64_decode($api_token);
            $key = openssl_get_privatekey($key);
            openssl_private_decrypt( $api_token, $credentials, $key );
            if( empty( $credentials ) ) return 0;
            $credentials = explode( ":", $credentials );
            if( count( $credentials ) !== 2 ) return 0;
            return array( 'user' => $credentials[0], 'pass' => $credentials[1] );
        }

        private static function get_tCMS_basedir() {
            $file = realpath( __FILE__ . "../../../basedir" );
            $exists = ( file_exists( $file ) ? explode( "\n", file_get_contents($file) )[0] : "/" );
        }

    }
?>
