<?php
    if( empty( $_SERVER["HTTPS"] ) ) {
        http_response_code(301);
        header("Location: https://" . $_SERVER["SERVER_NAME"] . "/" . $_SERVER["REQUEST_URI"]);
        die();
    }
    $loginFailure = -1;
    $supported_methods = [ 'GET', 'POST' ];
    if( in_array( $_SERVER['REQUEST_METHOD'], $supported_methods ) ) {
        switch($_SERVER['REQUEST_METHOD']) {
            case 'GET' : $request = &$_GET; break;
            case 'POST': $request = &$_POST; break;
        }
        $args = [];
        foreach( $request  as $key => $val ) {
            //Clean the junk
            $args[$key] = urldecode(filter_var( $val, FILTER_SANITIZE_ENCODED, FILTER_SANITIZE_SPECIAL_CHARS ));
        }
        $loginMsg = "Unknown Error";
        if( $_SERVER['REQUEST_METHOD'] === 'POST' ) {
            require_once("$basedir/lib/auth.inc"); //Authenticate
            $auth = new auth;
            $login = $auth->do_auth( $args['username'], $args['password'] );
            if(!is_array($login) || !empty($login['err']) || empty( $login['success'] ) ) {
                $loginFailure = 1;
                if( !empty( $login['msg'] ) ) $loginMsg = $login['msg'];
                http_response_code(401);
            } else { # We succeeded
                $loginMsg = "Login Succeded, redirecting...";
                $loginFailure = 0;
            }
        }
    }
    # Construct the redirection URL
    if( empty( $args['to'] ) ) {
        $redir = 'index.php';
    } else {
        $redir = 'index.php?app=' . $args["to"];
    }
    $redirection_URL = "https://" . $_SERVER["SERVER_NAME"] . "/sys/admin/$redir";
?>

<!doctype html>
<html dir="ltr" lang="en-US">
  <head>
    <title>tCMS 2 ~ Login</title>
    <style>
      body {
        background-color: gray;
        font-family: sans-serif;
      }
      #login {
        margin: 0 auto;
        max-width: 25rem;
        color: white;
      }
      #logo {
        display: block;
        max-width: 90%;
        margin: 0 0 0 5%;
        height: 2rem;
      }
      #login form {
        max-width: 85%;
        display: block;
        margin: 0 auto;
      }
      #maximumGo {
        width: calc(100% - 1rem);
      }
      #copyright {
        font-size: .75rem;
        text-align: center;
      }
      #jsalert {
        margin: 1rem;
        border-radius: .75rem;
        border-color: rgba(255,0,0,.75);
        padding: 1rem;
      }
      .alert-danger {
        background-color: rgba(255,0,0,.25);
      }
      .alert-success {
        background-color: rgba(0,255,0,.25);
      }
      input {
        box-sizing: border-box;
        border-radius: .5em;
        border: .25em solid black;
        color: white;
        padding: .25em;
        margin: .25em;
      }
      .input-group {
        display: table;
        width: 100%;
      }
      .input-group > input, .input-group > label {
        display: table-cell;
      }
      .input-group > input {
        width: calc(100% - 1rem);
        background-color: #333;
      }
      input[type="submit"] {
        box-shadow: 0 0 .5em black;
        background-color: #333;
        color: white;
      }
    </style>
    <script>
      document.addEventListener("DOMContentLoaded", function(event) {
        var loginFailure = <?php echo $loginFailure; ?>;
        if( loginFailure === -1 ) {
          document.querySelector('#jsalert').style.cssText = 'visibility: hidden;';
        } else if ( loginFailure === 1 ) {
          document.querySelector('#jsalert').classList.remove("alert-success");
          document.querySelector('#jsalert').classList.add("alert-danger");
          document.querySelector('#msgIcon').innerHTML = "❌";
          document.querySelector('#message').innerHTML = "<?php echo $loginMsg ?>";
        } else {
          document.querySelector('#jsalert').classList.remove("alert-danger");
          document.querySelector('#jsalert').classList.add("alert-success");
          document.querySelector('#msgIcon').innerHTML = "✓";
          document.querySelector('#message').innerHTML = "<?php echo $loginMsg ?>";
          window.setTimeout(function() {
            window.location="<?php echo $redirection_URL; ?>";
          }, 500);
        }
      });
    </script>
    <link rel="icon" type="image/vnd.microsoft.icon" href="../../img/icon/favicon.ico" />
  </head>
  <body>
      <div id="login">
        <div id="jsalert" class="alert-danger">
          <table>
            <tr>
              <td id="msgIcon">
                ⚠
              </td>
              <td id="message" style="padding-left: 1rem;">
                Please enable JavaScript on this domain.
              </td>
            </tr>
          </table>
        </div>
        <div>
          <img id="logo" src="../../img/icon/tCMS.svg" style="float:left" /><span style="font-family:courier;font-size:2rem;">CMS Login</span>
        </div>
        <div id="spacer" style="clear: both;"><br /></div>
        <form method="POST" action="index.php">
          <input type="hidden" name="app" value="login" />
          <input type="hidden" name="to" value="<?php if(!empty($args['to'])) echo $args['to']; ?>" />
          Username<br />
          <div class="input-group">
            <label for="username">😎</span></label>
            <input name="username" id="username" placeholder="AzureDiamond" value="" type="text"></input>
          </div>
          <br />
          Password<br />
          <div class="input-group">
            <label for="password">🔑</label>
            <input name="password" id="password" placeholder="hunter2" value="" type="password"></input>
          </div>
          <br />
          <input type="submit" id="maximumGo" value="Log in"></input>
        </form>
      </div>
  </body>
</html>
