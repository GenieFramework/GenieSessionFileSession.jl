module GenieSessionFileSession

import Genie, GenieSession
import Serialization, Logging

const SESSIONS_PATH = Ref{String}(Genie.Configuration.isprod() ? "sessions" : mktempdir())

function sessions_path(path::String)
  SESSIONS_PATH[] = normpath(path) |> abspath
end
function sessions_path()
  SESSIONS_PATH[]
end


function setup_folder()
  if ! isdir(sessions_path())
    @debug "Attempting to create sessions folder at $(sessions_path())"

    mkpath(sessions_path())
  end
end


function __init__()
  setup_folder()
end


"""
    write(session::GenieSession.Session) :: GenieSession.Session

Persists the `Session` object to the file system, using the configured sessions folder and returns it.
"""
function write(session::GenieSession.Session) :: GenieSession.Session
  try
    write_session(session)

    return session
  catch ex
    @error "Failed to store session data"
    @error ex
  end

  try
    @error "Resetting session"

    session = GenieSession.Session(GenieSession.id())
    Genie.Cookies.set!(Genie.Router.params(Genie.Router.PARAMS_RESPONSE_KEY), GenieSession.session_key_name(), session.id, GenieSession.session_options())
    write_session(session)
    Genie.Router.params(GenieSession.PARAMS_SESSION_KEY, session)

    return session
  catch ex
    @error "Failed to regenerate and store session data. Giving up."
    @error ex
  end

  session
end


function write_session(session::GenieSession.Session)
  isdir(sessions_path()) || mkpath(sessions_path())

  open(joinpath(sessions_path(), session.id), "w") do io
    Serialization.serialize(io, session)
  end
end


"""
    read(session_id::Union{String,Symbol}) :: Union{Nothing,GenieSession.Session}
    read(session::GenieSession.Session) :: Union{Nothing,GenieSession.Session}

Attempts to read from file the session object serialized as `session_id`.
"""
function read(session_id::String) :: Union{Nothing,GenieSession.Session}
  try
    isfile(joinpath(sessions_path(), session_id)) || return nothing
  catch ex
    @debug "Failed to read session data"
    @debug ex

    return nothing
  end

  try
    open(joinpath(sessions_path(), session_id), "r") do (io)
      Serialization.deserialize(io)
    end
  catch ex
    @debug "Can't read session"
    # @error ex
  end
end

function read(session::GenieSession.Session) :: Union{Nothing,GenieSession.Session}
  read(session.id)
end

#===#
# IMPLEMENTATION

"""
    persist(s::Session) :: Session

Generic method for persisting session data - delegates to the underlying `SessionAdapter`.
"""
function GenieSession.persist(req::GenieSession.HTTP.Request, res::GenieSession.HTTP.Response, params::Dict{Symbol,Any}) :: Tuple{GenieSession.HTTP.Request,GenieSession.HTTP.Response,Dict{Symbol,Any}}
  write(params[GenieSession.PARAMS_SESSION_KEY])

  req, res, params
end
function GenieSession.persist(s::GenieSession.Session) :: GenieSession.Session
  write(s)
end


"""
    load(session_id::String) :: Session

Loads session data from persistent storage.
"""
function GenieSession.load(session_id::String) :: GenieSession.Session
  session = read(session_id)

  session === nothing ? GenieSession.Session(session_id) : (session)
end

end
