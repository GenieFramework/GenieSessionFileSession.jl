module GenieSessionFileSession

"""
    GenieSessionFileSession

Persist and load web session data as encrypted files on disk.

Creates the sessions folder if missing, writes sessions atomically,
and enforces per-session expiration via the `Session.expires_at` field
managed by `GenieSession`.

See also
- [`write_session(session::GenieSession.Session)`](@ref)
- [`read(session_id::String)`](@ref)
- [`GenieSession.persist(req,res,params)`](@ref)
- [`GenieSession.load(session_id)`](@ref)
"""

import Genie, GenieSession
import Dates, Logging, Serialization, Base64

const SESSIONS_PATH=Ref{String}(Genie.Configuration.isprod() ?
  "sessions" : mktempdir())

"""
    sessions_path(path::String)

Set the directory where session files are stored.
All subsequent reads/writes will use this path.
"""
function sessions_path(path::String)
  SESSIONS_PATH[]=normpath(path)|>abspath
end

"""
    sessions_path()::String

Return the current sessions directory.
"""
function sessions_path()::String
  SESSIONS_PATH[]
end

"""
    setup_folder()::Nothing

Ensure that the sessions directory exists on disk, creating it if needed.
"""
function setup_folder()::Nothing
  if ! isdir(sessions_path())
    @debug "Attempting to create sessions folder at $(sessions_path())"
    mkpath(sessions_path())
  end

  nothing
end

"""
    __init__()::Nothing

Module initializer: called once when GenieSessionFileSession is loaded.
Creates the sessions folder if missing.
"""
function __init__()::Nothing
  setup_folder()
end

"""
    write(session::GenieSession.Session)::GenieSession.Session

Use a high-level interface for persisting a `Session`.
It ensures the folder exists, then calls `write_session`.
Last it returns the session unchanged.
"""
function write(session::GenieSession.Session)::GenieSession.Session
  try
    setup_folder()
    write_session(session)
    session
  catch ex
    @error "Failed to store session data"
    @error ex

    try
      @error "Resetting session"
      session=GenieSession.Session(GenieSession.id())

      Genie.Cookies.set!(
        Genie.Router.params(Genie.Router.PARAMS_RESPONSE_KEY),
        GenieSession.session_key_name(),
        session.id,
        GenieSession.session_options()
      )

      write_session(session)
      Genie.Router.params(GenieSession.PARAMS_SESSION_KEY, session)

      session
    catch ex2
      @error "Failed to regenerate and store session data. Giving up."
      @error ex2
      session
    end
  end
end

"""
    write_session(session::GenieSession.Session)::GenieSession.Session

Serialize the entire session object to a binary blob using Julia’s Serialization,
Base64-encode that blob, encrypt the resulting string (producing a hex token),
and atomically write it to disk at `sessions_path()/session.id`.

After writing, the function returns the same session object.

See also [`read(session_id::String)`](@ref),
[`GenieSession.persist`](@ref) and [`Genie.Encryption.encrypt`](@ref).
"""
function write_session(session::GenieSession.Session)::GenieSession.Session
  setup_folder()

  # 1) serialize to bytes
  buf=IOBuffer()
  Serialization.serialize(buf, session)
  raw=take!(buf)                  # Vector{UInt8}

  # 2) base64 → String
  b64=Base64.base64encode(raw)

  # 3) encrypt → hex string
  token=Genie.Encryption.encrypt(b64)  # String (hex)

  # 4) atomic write
  f=joinpath(sessions_path(), session.id)
  mkpath(dirname(f))
  tmp=f*".tmp"

  open(tmp, "w") do io
    Base.write(io, token)
  end

  mv(tmp, f; force=true)

  session
end

"""
    read(session_id::String)::Union{Nothing,GenieSession.Session}

Load a session by ID as follows:
1. Read the on-disk hex token from the file located at
   `sessions_path()/session_id`.
2. Decrypt the token to recover the Base64-encoded session data.
3. Base64-decode the result to obtain the raw serialized bytes.
4. Deserialize those bytes to reconstruct the original `Session` object.
5. Enforce the session’s TTL: if the current time exceeds `session.expires_at`,
   the session is considered expired and the function returns `nothing`.

See also [`write_session(session::GenieSession.Session)`](@ref),
[`GenieSession.load`](@ref) and [`Genie.Encryption.decrypt`](@ref).
"""
function read(session_id::String)::Union{Nothing,GenieSession.Session}
  f=joinpath(sessions_path(), session_id)
  ! isfile(f) && return nothing

  # 1) read the encrypted hex string
  token=try
    Base.read(f, String)
  catch ex
    @debug "Failed to read session data"
    @debug ex
    return nothing
  end

  # 2) decrypt → base64
  b64=try
    Genie.Encryption.decrypt(token)
  catch ex
    @debug "Failed to decrypt session $session_id"
    @debug ex
    return nothing
  end

  isempty(b64) && return nothing

  # 3) base64 → raw bytes
  raw=try
    Base64.base64decode(b64)
  catch ex
    @debug "Failed to base64-decode session $session_id"
    @debug ex
    return nothing
  end

  # 4) deserialize → Session
  session=try
    io=IOBuffer(raw)
    Serialization.deserialize(io)
  catch ex
    @debug "Failed to deserialize session $session_id"
    @debug ex
    return nothing
  end

  # ensure it is our Session type
  isa(session, GenieSession.Session) || return nothing

  # 5) TTL check: respect Session.expires_at if present
  if Base.hasfield(GenieSession.Session, :expires_at)
    if Dates.now()>session.expires_at
      @debug "Session $session_id expired at $(session.expires_at)"
      return nothing
    end
  end

  session
end

"""
    read(session::GenieSession.Session)::Union{GenieSession.Session,Nothing}

Read a session from disk using its `session.id` (helper overload).
"""
function read(session::GenieSession.Session)::Union{Nothing,GenieSession.Session}
  read(session.id)
end

"""
    GenieSession.persist(req::GenieSession.HTTP.Request,
                         res::GenieSession.HTTP.Response,
                         params::Dict{Symbol,Any})

Persist the session stored in `params[:SESSION]` to disk, then return
the unchanged `(req, res, params)` tuple.

See also [`write_session(session)`](@ref),
[`GenieSession.persist(s::Session)`](@ref) and [`GenieSession.load(session_id)`](@ref).
"""
function GenieSession.persist(
  req::GenieSession.HTTP.Request,
  res::GenieSession.HTTP.Response,
  params::Dict{Symbol,Any}
)::Tuple{GenieSession.HTTP.Request,GenieSession.HTTP.Response,Dict{Symbol,Any}}
  write(params[GenieSession.PARAMS_SESSION_KEY])
  req, res, params
end

"""
    GenieSession.persist(s::GenieSession.Session)::GenieSession.Session

Persist the in-memory session `s` to disk using the configured session adapter
and return the same `Session` object.

See also [`write_session(session)`](@ref) and
[`GenieSession.load(session_id)`](@ref).
"""
function GenieSession.persist(s::GenieSession.Session)::GenieSession.Session
  write(s)
end

"""
    GenieSession.load(session_id::String)::GenieSession.Session

Load and decrypt the session identified by `session_id`. If no valid
session file exists or it has expired, return a fresh `Session(session_id)`.

See also [`read(session_id)`](@ref) and
[`GenieSession.persist(req,res,params)`](@ref).
"""
function GenieSession.load(session_id::String)::GenieSession.Session
  session=read(session_id)
  session===nothing ? GenieSession.Session(session_id) : session
end

"""
    rotate_file_session!(
      sess::GenieSession.Session,
      req::GenieSession.HTTP.Request,
      res::GenieSession.HTTP.Response;
      options=GenieSession.session_options()
    )::GenieSession.Session

Rotate the session ID using `GenieSession.rotate!`, then delete the old
on-disk session file managed by this adapter. Use this helper when you
know you are using file-backed sessions and want to clean up the old
session store on rotation.
"""
function rotate_file_session!(
  sess::GenieSession.Session,
  req::GenieSession.HTTP.Request,
  res::GenieSession.HTTP.Response;
  options::Dict{String,Any}=GenieSession.session_options()
)::GenieSession.Session
  oldid=sess.id

  GenieSession.rotate!(sess, req, res; options=options)

  f=joinpath(sessions_path(), oldid)
  isfile(f) && rm(f; force=true)

  sess
end

end
