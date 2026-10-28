-- Indexes that serve a foreign key's checks (native 0.10 / SQL edition 0.7).
-- Those checks run as nested statements, often not recorded, so such an
-- index is noted and gets a drop_blocker instead of being a drop candidate.
CREATE TABLE fkp (id int PRIMARY KEY, a int, b int, c int, d int,
                  UNIQUE (a, b), UNIQUE (c, d));
CREATE TABLE fkc (id int PRIMARY KEY,
                  pid int REFERENCES fkp,
                  a int, b int, c int, d int, z int, flag bool,
                  FOREIGN KEY (a, b) REFERENCES fkp (a, b),
                  FOREIGN KEY (c, d) REFERENCES fkp (c, d));
CREATE INDEX fkc_pid_idx ON fkc (pid);              -- exact: supports fkc_pid_fkey
CREATE INDEX fkc_ba_idx ON fkc (b, a);              -- exact, other order: supports (a, b)
CREATE INDEX fkc_a_idx ON fkc (a);                  -- prefix only, but (b, a) exists: no
CREATE INDEX fkc_cz_idx ON fkc (c, z);              -- prefix, and no exact index for (c, d): supports
CREATE INDEX fkc_pid_part_idx ON fkc (pid) WHERE flag;  -- partial: no
CREATE INDEX fkc_z_idx ON fkc (z);                  -- unrelated: no
CREATE INDEX fkc_zpid_idx ON fkc (z, pid);          -- FK column not leading: no
CREATE INDEX fkc_pid_incl_idx ON fkc (pid) INCLUDE (a);  -- exact, with INCLUDE: supports
SELECT c.relname AS indexname, r.drop_blocker IS NOT NULL AS blocked,
       (SELECT string_agg(n, '; ') FROM unnest(r.index_notes) n WHERE n LIKE 'supports%') AS supports
  FROM pg_class c, LATERAL index_deps.index_role(c.oid) r
 WHERE c.relname LIKE 'fkc\_%' AND c.relkind = 'i'
 ORDER BY 1;
SELECT r.drop_blocker FROM index_deps.index_role('fkc_ba_idx') r;
DROP TABLE fkc, fkp;
