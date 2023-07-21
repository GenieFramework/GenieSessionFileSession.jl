module GenieSessionFileSession

import Genie, GenieSession
import Serialization, Logging
using Genie.Context

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
function GenieSession.write(params::Params) :: GenieSession.Session
  try
    write_session(params[:session])

    return params[:session]
  catch ex
    @error "Failed to store session data"
    @error ex
  end

  try
    @error "Resetting session"

    session = GenieSession.Session(GenieSession.id())
    Genie.Cookies.set!(params[:response], GenieSession.session_key_name(), session.id, GenieSession.session_options())
    write_session(session)

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
    @debug ex
  end
end

function read(session::GenieSession.Session) :: Union{Nothing,GenieSession.Session}
  read(session.id)
end

#===#
# IMPLEMENTATION


"""
    load(req::HTTP.Request, res::HTTP.Response, session_id::String) :: Session

Loads session data from persistent storage.
"""
function GenieSession.load(req, res, session_id::String) :: GenieSession.Session
  session = read(session_id)

  session === nothing ? GenieSession.Session(session_id) : (session)
end

end
