-- A password reset kept the new password here, as plain text, until it was
-- used.  Trog::Auth no longer writes this column, so clear what it left.
UPDATE change_request SET secret = NULL;
