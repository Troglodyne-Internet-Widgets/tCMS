/* CREATE VIEW IF NOT EXISTS leaves an older all_routes in place, so drop it first. */
DROP VIEW IF EXISTS all_routes;
CREATE VIEW all_routes AS SELECT r.id AS id, r.route AS route, m.method AS method, c.callback AS callback,
    EXISTS (SELECT 1 FROM posts_index AS p JOIN tag AS t ON t.id=p.tag_id WHERE p.post_id=r.post_id AND t.name='private') AS secure
    FROM routes AS r JOIN methods AS m ON m.id=r.method_id JOIN callbacks AS c ON c.id=r.callback_id;
