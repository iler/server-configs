# Customized VCL file for serving a Drupal site.

# Settings for a request that determines if a web backend is alive and well.
probe healthcheck {
   .url = "/_monitor.php";
   .interval = 20s;
   .timeout = 3s;
   .window = 8;
   .threshold = 3;
   .initial = 3;
   .expected_response = 200;
}

# Default backend definition.  Set this to point to your content server.
backend default {
  .host = "127.0.0.1";
  .port = "8080";
  .connect_timeout = 600s;
  .first_byte_timeout = 600s;
  .between_bytes_timeout = 600s;
}

# Web backend 1
backend web1 {
 .host = "192.168.0.1";
 .port = "80";
 .first_byte_timeout = 600s;
 .probe = healthcheck;
}

# Web backend 2
backend web2 {
 .host = "192.168.0.2";
 .port = "80";
 .first_byte_timeout = 600s;
 .probe = healthcheck;
} 

# Define the director that determines how to distribute incoming requests.
director default_director round-robin {
  { .backend = web1; }
  { .backend = web2; }
}

# Define the internal network access.
# These are used below to allow internal access to certain files
# from offices while not allowing access from the public internet.
acl internal {
  # localhost
  "127.0.0.1";
  # office
  "192.168.1.1";
}

sub vcl_error {
  set obj.http.Content-Type = "text/html; charset=utf-8";
  if (obj.status == 401) {
    set obj.http.WWW-Authenticate = "Basic realm=Secured";
    synthetic {"
      <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN"
      "http://www.w3.org/TR/1999/REC-html401-19991224/loose.dtd">
      <HTML>
      <HEAD><TITLE>Error</TITLE><META HTTP-EQUIV='Content-Type' CONTENT='text/html;'></HEAD>
      <BODY><H1>401 Unauthorized (varnish)</H1></BODY>
      </HTML>
    "};
  }
  else {
    synthetic {"
     <?xml version="1.0" encoding="utf-8"?>
     <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
     "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
      <html>
        <head>
          <title>"} obj.status " " obj.response {"</title>
        </head>
        <body>
         <h1>We are performing temporary maintenance.</h1><p style="font-size:small;"><i>Error: "} obj.status " " obj.response {"</i></p>
        </body>
      </html>
    "};
  }
  return (deliver);
}

sub vcl_recv {

  // HTTP authentication with varnish for non-internal ip addresses only.
  // No auth configurations with Apache/Nginx. This way we can preserve
  // varnish page caching.
  if (!client.ip ~ internal) {
    if (req.http.Authorization ~ "c29tZXVzZXJuYW1lOnNvbWVwYXNzd29yZA==") {
      // Base64 encoded string c29tZXVzZXJuYW1lOnNvbWVwYXNzd29yZA==
      // is someusername:somepassword when decoded.
      // To choose the username and password
      // use e.g. http://www.opinionatedgeek.com/dotnet/tools/base64encode/
      unset req.http.Authorization;
    }
    else {
      error 401 "Restricted";
    }
  }

  set req.backend = default_director;

  # Use anonymous, cached pages if all backends are down.
  if (!req.backend.healthy) {
    unset req.http.Cookie;
  }
  
  # Allow the backend to serve up stale content if it is responding slowly.
  set req.grace = 6h;
  
  // Add a unique header containing the client address
  remove req.http.X-Forwarded-For;
  set    req.http.X-Forwarded-For = client.ip;

  if (req.request != "GET" && req.request != "HEAD") {
    /* We only deal with GET and HEAD by default */
    return (pass);
  }

  // No varnish for monitor file (for monitoring tools)
  if (req.url ~ "_monitor.php") {
    return (pass);
  }
  
  if (req.url ~ "\.(png|gif|jpg|tif|tiff|ico|swf|css|js|pdf|doc|xls|ppt|zip)(\?.*)?$") {
    // Forcing a lookup with static file requests
    return (lookup);
  }

  # Do not allow public access to cron.php , update.php or install.php.
  if (req.url ~ "^/(cron|install|update)\.php$" && !client.ip ~ internal) {
    # Have Varnish throw the error directly.
    error 404 "Page not found.";
  }

  # Do not cache these paths.
  if (req.url ~ "^/update\.php$" ||
      req.url ~ "^/install\.php$" ||
      req.url ~ "^/cron\.php$" ||
      req.url ~ "^/ooyala/ping$" ||
      req.url ~ "^/admin/build/features" ||
      req.url ~ "^/info/.*$" ||
      req.url ~ "^/flag/.*$" ||
      req.url ~ "^.*/ajax/.*$" ||
      req.url ~ "^.*/ahah/.*$" ||
      req.url ~ "^/radioactivity_node.php$") {
       return (pass);
  }

  if (req.http.Cookie) {
    if (req.url ~ "\.(png|gif|jpg|tif|tiff|ico|swf|css|js|pdf|doc|xls|ppt|zip|woff|eot|ttf)$") {
      # Static file request do not vary on cookies
      unset req.http.Cookie;
    }
    elseif (req.http.Cookie ~ "(^|\s)SESS[a-z0-9]+") {
      # Authenticated users should not be cached
      return (pass);
    }
    else {
      # Non-authenticated requests do not vary on cookies
      unset req.http.Cookie;
    }
  }

  if (req.http.Accept-Encoding) {
    if (req.url ~ "\.(jpg|png|gif|tif|tiff|ico|gz|tgz|bz2|tbz|mp3|ogg|swf|zip|pdf|woff|eot|ttf)(\?.*)?$") {
        # No point in compressing these
        unset req.http.Accept-Encoding;
    } elsif (req.http.Accept-Encoding ~ "gzip") {
        set req.http.Accept-Encoding = "gzip";
    } elsif (req.http.Accept-Encoding ~ "deflate") {
        set req.http.Accept-Encoding = "deflate";
    } else {
        # unkown algorithm
        unset req.http.Accept-Encoding;
    }
  }
  // Keep multiple cache objects to a minimum
  unset req.http.Accept-Language;
  unset req.http.user-agent;

}

sub vcl_fetch {

  if (req.url ~ "\.(png|gif|jpg|tif|tiff|ico|swf|css|js|pdf|doc|xls|ppt|zip|woff|eot|ttf)(\?.*)?$") {
    # Strip any cookies before static files are inserted into cache.
    unset beresp.http.set-cookie;
    set beresp.ttl = 1w;
    set beresp.http.isstatic = "1";
  }

  if (beresp.status == 404) {
    if (beresp.http.isstatic) {
      /*
       * 404s for static files might include profile data since they're actually Drupal pages.
       * See sites/default/settings.php for how 404s are implemented "the fast way"
       */
      set beresp.ttl = 0s;
    }
  }
  
  # Allow items to be stale if needed.
  set beresp.grace = 6h;

}

sub vcl_deliver {
  if (obj.hits > 0) {
    set resp.http.X-Varnish-Cache = "HIT";
  }
  else {
    set resp.http.X-Varnish-Cache = "MISS";
  }
  if (resp.http.isstatic) {
    unset resp.http.isstatic;
  }
  remove resp.http.X-Varnish;
  remove resp.http.Via;
  remove resp.http.Server;
  remove resp.http.X-Powered-By;
}