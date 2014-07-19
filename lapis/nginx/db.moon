
-- This is a simple interface form making queries to postgres on top of
-- ngx_postgres
--
-- Add the following upstream to your http:
--
-- upstream database {
--   postgres_server  127.0.0.1 dbname=... user=... password=...;
-- }
--
-- Add the following location to your server:
--
-- location /query {
--   postgres_pass database;
--   postgres_query $echo_request_body;
-- }
--

import concat from table

local raw_query, dialect

proxy_location = "/query"

logger = require "lapis.logging"

set_logger = (l) -> logger = l
get_logger = -> logger
get_dialect = -> dialect

import type, tostring, pairs, select from _G

NULL = {}
NULL = ngx.null if ngx
raw = (val) -> {"raw", tostring(val)}
is_raw = (val) ->
  type(val) == "table" and val[1] == "raw" and val[2]

TRUE = raw"TRUE"
FALSE = raw"FALSE"

dialects = {
  postgres: {
    drop_index_if_exists: true
    explicit_time_zone: true
    index_where: true
    rename_column: true
    restart_identity: " RESTART IDENTITY"
    returning: true
    row_if_entity_exists: "0 from pg_class where relname = ? limit 1"
  }
  mysql: {
    restart_identity: ""
    row_if_entity_exists: "0 from information_schema.tables where table_schema = database() limit 1"
  }
}

backends = {
  default: (_proxy=proxy_location) ->
    parser = require "rds.parser"
    dialect = dialects.postgres
    raw_query = (str) ->
      logger.query str if logger
      res, m = ngx.location.capture _proxy, {
        body: str
      }
      out, err = parser.parse res.body
      error "#{err}: #{str}" unless out

      if resultset = out.resultset
        return resultset
      out

  raw: (fn, fn_dialect=dialects.postgres) ->
    dialect = fn_dialect
    with raw_query
      raw_query = fn

  pgmoon: ->
    import after_dispatch from require "lapis.nginx.context"
    config = require("lapis.config").get!
    pg_config = assert config.postgres, "missing postgres configuration"

    dialect = dialects.postgres
    raw_query = (str) ->
      pgmoon = ngx and ngx.ctx.pgmoon
      unless pgmoon
        import Postgres from require "pgmoon"
        pgmoon = Postgres pg_config
        assert pgmoon\connect!

        if ngx
          ngx.ctx.pgmoon = pgmoon
          after_dispatch -> pgmoon\keepalive!

      logger.query "[PGMOON] #{str}" if logger
      res, err = pgmoon\query str
      if not res and err
        error "#{str}\n#{err}"
      res

  resty_mysql: ->
    import after_dispatch from require "lapis.nginx.context"
    config = require("lapis.config").get!
    mysql_config = assert config.mysql, "missing postgres configuration"

    dialect = dialects.mysql
    raw_query = (str) ->
      mysql = ngx and ngx.ctx.mysql
      unless mysql
        mysql = assert (require "resty.mysql")\new!
        mysql\set_timeout 1000 -- 1 s
        assert mysql\connect mysql_config

        if ngx
          ngx.ctx.mysql = mysql
          after_dispatch -> mysql\set_keepalive 10000, 100 -- 10 s in a pool of 100

      logger.query "[mysql] #{str}" if logger
      assert mysql\query str
}

set_backend = (name="default", ...) ->
  assert(backends[name]) ...

format_date = (time) ->
  os.date "!%Y-%m-%d %H:%M:%S", time

append_all = (t, ...) ->
  for i=1, select "#", ...
    t[#t + 1] = select i, ...

escape_identifier = (ident) ->
  if type(ident) == "table" and ident[1] == "raw"
    return ident[2]

  ident = tostring ident
  '"' ..  (ident\gsub '"', '""') .. '"'

escape_literal = (val) ->
  switch type val
    when "number"
      return tostring val
    when "string"
      return "'#{(val\gsub "'", "''")}'"
    when "boolean"
      return val and "TRUE" or "FALSE"
    when "table"
      return "NULL" if val == NULL
      if val[1] == "raw" and val[2]
        return val[2]

  error "don't know how to escape value: #{val}"

-- replace ? with values
interpolate_query = (query, ...) ->
  values = {...}
  i = 0
  (query\gsub "%?", ->
    i += 1
    escape_literal values[i])

-- (col1, col2, col3) VALUES (val1, val2, val3)
encode_values = (t, buffer) ->
  have_buffer = buffer
  buffer or= {}

  tuples = [{k,v} for k,v in pairs t]
  cols = concat [escape_identifier pair[1] for pair in *tuples], ", "
  vals = concat [escape_literal pair[2] for pair in *tuples], ", "

  append_all buffer, "(", cols, ") VALUES (", vals, ")"
  concat buffer unless have_buffer

-- col1 = val1, col2 = val2, col3 = val3
encode_assigns = (t, buffer) ->
  join = ", "
  have_buffer = buffer
  buffer or= {}

  for k,v in pairs t
    append_all buffer, escape_identifier(k), " = ", escape_literal(v), join

  buffer[#buffer] = nil

  concat buffer unless have_buffer

encode_clause = (t, buffer)->
  join = " AND "
  have_buffer = buffer
  buffer or= {}

  for k,v in pairs t
    if v == NULL
      append_all buffer, escape_identifier(k), " IS NULL", join
    else
      append_all buffer, escape_identifier(k), " = ", escape_literal(v), join

  buffer[#buffer] = nil

  concat buffer unless have_buffer

raw_query = (...) ->
  config = require("lapis.config").get!
  default_backend = config.mysql and (config.mysql.backend or "resty_mysql")
  default_backend = default_backend or (config.postgres and config.postgres.backend)
  default_backend = default_backend or "default"
  set_backend default_backend
  raw_query ...

query = (str, ...) ->
  if select("#", ...) > 0
    str = interpolate_query str, ...
  raw_query str

_select = (str, ...) ->
  query "SELECT " .. str, ...

_insert = (tbl, values, ...) ->
  if values._timestamp
    values._timestamp = nil
    time = format_date!

    values.created_at or= time
    values.updated_at or= time

  buff = {
    "INSERT INTO "
    escape_identifier(tbl)
    " "
  }
  encode_values values, buff

  returning = {...}
  if next returning
    error "RETURNING not implemented for mysql" unless dialect.returning
    append_all buff, " RETURNING "
    for i, r in ipairs returning
      append_all buff, escape_identifier r
      append_all buff, ", " if i != #returning

  raw_query concat buff

add_cond = (buffer, cond, ...) ->
  append_all buffer, " WHERE "
  switch type cond
    when "table"
      encode_clause cond, buffer
    when "string"
      append_all buffer, interpolate_query cond, ...

_update = (table, values, cond, ...) ->
  if values._timestamp
    values._timestamp = nil
    values.updated_at or= format_date!

  buff = {
    "UPDATE "
    escape_identifier(table)
    " SET "
  }

  encode_assigns values, buff

  if cond
    add_cond buff, cond, ...

  raw_query concat buff

_delete = (table, cond, ...) ->
  buff = {
    "DELETE FROM "
    escape_identifier(table)
  }

  if cond
    add_cond buff, cond, ...

  raw_query concat buff

-- truncate many tables
_truncate = (...) ->
  tables = concat [escape_identifier t for t in *{...}], ", "
  raw_query "TRUNCATE " .. tables .. dialect.restart_identity

parse_clause = do
  local grammar
  make_grammar = ->
    keywords = {"where", "group", "having", "order", "limit", "offset"}
    for v in *keywords
      keywords[v] = true

    import P, R, C, S, Cmt, Ct, Cg from require "lpeg"

    alpha = R("az", "AZ", "__")
    alpha_num = alpha + R("09")
    white = S" \t\r\n"^0
    word = alpha_num^1

    single_string = P"'" * (P"''" + (P(1) - P"'"))^0 * P"'"
    double_string = P'"' * (P'""' + (P(1) - P'"'))^0 * P'"'
    strings = single_string + double_string

    keyword = Cmt word, (src, pos, cap) ->
      if keywords[cap\lower!]
        true, cap

    keyword = keyword * white

    clause = Ct (keyword * C (strings + (word + P(1) - keyword))^1) / (name, val) ->
      if name == "group" or name == "order"
        val = val\match "^%s*by%s*(.*)$"

      name, val

    grammar = white * Ct clause^0

  (clause) ->
    make_grammar! unless grammar
    if out = grammar\match clause
      { unpack t for t in *out }

{
  :query, :raw, :is_raw, :NULL, :TRUE, :FALSE, :escape_literal,
  :escape_identifier, :encode_values, :encode_assigns, :encode_clause,
  :interpolate_query, :parse_clause, :set_logger, :get_logger, :format_date,

  :set_backend, :get_dialect

  select: _select
  insert: _insert
  update: _update
  delete: _delete
  truncate: _truncate
}