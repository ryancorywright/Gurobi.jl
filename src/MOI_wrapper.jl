import MathOptInterface

const MOI = MathOptInterface
const CleverDicts = MOI.Utilities.CleverDicts

@enum(VariableType, CONTINUOUS, BINARY, INTEGER, SEMIINTEGER, SEMICONTINUOUS)
@enum(BoundType, NONE, LESS_THAN, GREATER_THAN, LESS_AND_GREATER_THAN, INTERVAL, EQUAL_TO)
@enum(ObjectiveType, SINGLE_VARIABLE, SCALAR_AFFINE, SCALAR_QUADRATIC)
@enum(CallbackState, CB_NONE, CB_GENERIC, CB_LAZY, CB_USER_CUT, CB_HEURISTIC)

const SCALAR_SETS = Union{
    MOI.GreaterThan{Float64}, MOI.LessThan{Float64},
    MOI.EqualTo{Float64}, MOI.Interval{Float64}
}

mutable struct VariableInfo
    index::MOI.VariableIndex
    column::Int
    bound::BoundType
    # Both fields below are cached values to avoid triggering a model_update!
    # if the variable bounds are queried. They are non-NaN only if `bound` is
    # different from NONE. EQUAL_TO sets both of them. See also
    # `lower_bound_if_soc`.
    lower_bound_if_bounded::Float64
    upper_bound_if_bounded::Float64
    type::VariableType
    start::Union{Float64, Nothing}
    name::String
    # Storage for constraint names associated with variables because Gurobi
    # can only store names for variables and proper constraints.
    # We can perform an optimization and only store three strings for the
    # constraint names because, at most, there can be three SingleVariable
    # constraints, e.g., LessThan, GreaterThan, and Integer.
    lessthan_name::String
    greaterthan_interval_or_equalto_name::String
    type_constraint_name::String
    # Storage for the lower bound if the variable is the `t` variable in a
    # second order cone. Theoretically, if both `lower_bound_if_bounded` and
    # `lower_bound_if_soc` are non-NaN, then they have the same value,
    # but you can also just have SOC constraints, or just have bounds, or
    # have a bound and have a SOC constraint that does not need to set
    # `lower_bound_if_soc` (in all such cases just one of them is NaN).
    lower_bound_if_soc::Float64
    num_soc_constraints::Int
    function VariableInfo(index::MOI.VariableIndex, column::Int)
        return new(index, column, NONE, NaN, NaN, CONTINUOUS, nothing, "", "", "", "", NaN, 0)
    end
end

mutable struct ConstraintInfo
    row::Int
    set::MOI.AbstractSet
    # Storage for constraint names. Where possible, these are also stored in the
    # Gurobi model.
    name::String
    ConstraintInfo(row::Int, set) = new(row, set, "")
end

mutable struct Optimizer <: MOI.AbstractOptimizer
    # The low-level Gurobi model.
    inner::Model
    # The Gurobi environment. If `nothing`, a new environment will be created
    # on `MOI.empty!`.
    env::Union{Nothing, Env}
    # The current user-provided parameters for the model.
    params::Dict{String, Any}

    # The next field is used to cleverly manage calls to `update_model!`.
    # `needs_update` is used to record whether an update should be called before
    # accessing a model attribute (such as the value of a RHS term).
    needs_update::Bool

    # A flag to keep track of MOI.Silent, which over-rides the OutputFlag
    # parameter.
    silent::Bool

    # An enum to remember what objective is currently stored in the model.
    objective_type::ObjectiveType

    # A flag to keep track of MOI.FEASIBILITY_SENSE, since Gurobi only stores
    # MIN_SENSE or MAX_SENSE. This allows us to differentiate between MIN_SENSE
    # and FEASIBILITY_SENSE.
    is_feasibility::Bool

    # A mapping from the MOI.VariableIndex to the Gurobi column. VariableInfo
    # also stores some additional fields like what bounds have been added, the
    # variable type, and the names of SingleVariable-in-Set constraints.
    variable_info::CleverDicts.CleverDict{MOI.VariableIndex, VariableInfo}

    # If you add variables to a model that had variables deleted AND has
    # not called `update_model!` since the deletion, then the newly created
    # variables may have attributes set, but their column index before the
    # call to `update_model!` is different than after the `update_model!`.
    # Before the `update_model!` their column is the same as if no variables
    # were deleted, after the `update_model!` the columns indexes are
    # shifted (by being being subtracted by the number of variables deleted
    # with column indexes smaller than them). To control this the two
    # fields below are used:
    # `next_column`: The column index of the next variable/column added. It is
    # updated when variables are added, and when the `_update_if_necessary!` is
    # called AND `columns_deleted_since_last_update` is not empty.
    # `columns_deleted_since_last_update`: Stores the column indexes of all
    # columns that were deleted since the last call to `_update_if_necessary!`,
    # after such call the vector is emptied.
    next_column::Int
    columns_deleted_since_last_update::Vector{Int}

    # An index that is incremented for each new constraint (regardless of type).
    # We can check if a constraint is valid by checking if it is in the correct
    # xxx_constraint_info. We should _not_ reset this to zero, since then new
    # constraints cannot be distinguished from previously created ones.
    last_constraint_index::Int
    # ScalarAffineFunction{Float64}-in-Set storage.
    affine_constraint_info::Dict{Int, ConstraintInfo}
    # ScalarQuadraticFunction{Float64}-in-Set storage.
    quadratic_constraint_info::Dict{Int, ConstraintInfo}
    # VectorOfVariables-in-Set storage.
    sos_constraint_info::Dict{Int, ConstraintInfo}
    # Note: we do not have a singlevariable_constraint_info dictionary. Instead,
    # data associated with these constraints are stored in the VariableInfo
    # objects.

    # Mappings from variable and constraint names to their indices. These are
    # lazily built on-demand, so most of the time, they are `nothing`.
    name_to_variable::Union{Nothing, Dict{String, Union{Nothing, MOI.VariableIndex}}}
    name_to_constraint_index::Union{Nothing, Dict{String, Union{Nothing, MOI.ConstraintIndex}}}

    # These two flags allow us to distinguish between FEASIBLE_POINT and
    # INFEASIBILITY_CERTIFICATE when querying VariablePrimal and ConstraintDual.
    has_unbounded_ray::Bool
    has_infeasibility_cert::Bool

    # Callback fields.
    callback_variable_primal::Vector{Float64}
    has_generic_callback::Bool
    callback_state::CallbackState
    lazy_callback::Union{Nothing, Function}
    user_cut_callback::Union{Nothing, Function}
    heuristic_callback::Union{Nothing, Function}

    """
        Optimizer(env = nothing; kwargs...)

    Create a new Optimizer object.

    You can share Gurobi `Env`s between models by passing an instance of `Env`
    as the first argument. By default, a new environment is created for every
    model.
    """
    function Optimizer(env::Union{Nothing, Env} = nothing; kwargs...)
        model = new()
        model.env = env
        model.silent = false
        model.params = Dict{String, Any}()
        model.variable_info = CleverDicts.CleverDict{MOI.VariableIndex, VariableInfo}()
        model.next_column = 1
        model.columns_deleted_since_last_update = Int[]
        model.affine_constraint_info = Dict{Int, ConstraintInfo}()
        model.quadratic_constraint_info = Dict{Int, ConstraintInfo}()
        model.sos_constraint_info = Dict{Int, ConstraintInfo}()
        model.callback_variable_primal = Float64[]
        MOI.empty!(model)  # MOI.empty!(model) re-sets the `.inner` field.
        for (name, value) in kwargs
            model.params[string(name)] = value
            setparam!(model.inner, string(name), value)
        end
        return model
    end
end

Base.show(io::IO, model::Optimizer) = show(io, model.inner)

function MOI.empty!(model::Optimizer)
    if model.env === nothing
        model.inner = Model(Env(), "", finalize_env = true)
    else
        model.inner = Model(model.env, "", finalize_env = false)
    end
    for (name, value) in model.params
        setparam!(model.inner, name, value)
    end
    if model.silent
        # Set the parameter on the internal model, but don't modify the entry in
        # model.params so that if Silent() is set to `true`, the user-provided
        # value will be restored.
        setparam!(model.inner, "OutputFlag", 0)
    end
    model.needs_update = false
    model.objective_type = SCALAR_AFFINE
    model.is_feasibility = true
    empty!(model.variable_info)
    model.next_column = 1
    empty!(model.columns_deleted_since_last_update)
    empty!(model.affine_constraint_info)
    empty!(model.quadratic_constraint_info)
    empty!(model.sos_constraint_info)
    model.name_to_variable = nothing
    model.name_to_constraint_index = nothing
    model.has_unbounded_ray = false
    model.has_infeasibility_cert = false
    empty!(model.callback_variable_primal)
    model.callback_state = CB_NONE
    model.has_generic_callback = false
    model.lazy_callback = nothing
    model.user_cut_callback = nothing
    model.heuristic_callback = nothing
    return
end

function MOI.is_empty(model::Optimizer)
    model.needs_update && return false
    model.objective_type != SCALAR_AFFINE && return false
    model.is_feasibility == false && return false
    !isempty(model.variable_info) && return false
    !isone(model.next_column) && return false
    !isempty(model.columns_deleted_since_last_update) && return false
    !isempty(model.affine_constraint_info) && return false
    !isempty(model.quadratic_constraint_info) && return false
    !isempty(model.sos_constraint_info) && return false
    model.name_to_variable !== nothing && return false
    model.name_to_constraint_index !== nothing && return false
    model.has_unbounded_ray && return false
    model.has_infeasibility_cert && return false
    !isempty(model.callback_variable_primal) && return false
    model.callback_state != CB_NONE && return false
    model.has_generic_callback && return false
    model.lazy_callback !== nothing && return false
    model.user_cut_callback !== nothing && return false
    model.heuristic_callback !== nothing && return false
    return true
end

"""
    _require_update(model::Optimizer)

Sets the `model.needs_update` flag. Call this at the end of any mutating method.
"""
function _require_update(model::Optimizer)
    model.needs_update = true
    return
end

"""
    _update_if_necessary(model::Optimizer)

Calls `update_model!`, but only if the `model.needs_update` flag is set.
"""
function _update_if_necessary(model::Optimizer)
    if model.needs_update
        sort!(model.columns_deleted_since_last_update)
        for var_info in values(model.variable_info)
            var_info.column -= searchsortedlast(
                 model.columns_deleted_since_last_update, var_info.column
            )
        end
        model.next_column -= length(model.columns_deleted_since_last_update)
        empty!(model.columns_deleted_since_last_update)
        update_model!(model.inner)
        model.needs_update = false
    else
        @assert isempty(model.columns_deleted_since_last_update)
    end
    return
end

MOI.get(::Optimizer, ::MOI.SolverName) = "Gurobi"

function MOI.supports(
    ::Optimizer,
    ::MOI.ObjectiveFunction{F}
) where {F <: Union{
    MOI.SingleVariable,
    MOI.ScalarAffineFunction{Float64},
    MOI.ScalarQuadraticFunction{Float64}
}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.SingleVariable}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64}, MOI.LessThan{Float64}, MOI.GreaterThan{Float64},
    MOI.Interval{Float64}, MOI.ZeroOne, MOI.Integer,
    MOI.Semicontinuous{Float64}, MOI.Semiinteger{Float64}
}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.VectorOfVariables}, ::Type{F}
) where {F <: Union{MOI.SOS1{Float64}, MOI.SOS2{Float64}, MOI.SecondOrderCone}}
    return true
end

# We choose _not_ to support ScalarAffineFunction-in-Interval and
# ScalarQuadraticFunction-in-Interval because Gurobi introduces some slack
# variables that makes it hard to keep track of the column indices.

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.ScalarAffineFunction{Float64}}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64}, MOI.LessThan{Float64}, MOI.GreaterThan{Float64}
}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.ScalarQuadraticFunction{Float64}}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64}, MOI.LessThan{Float64}, MOI.GreaterThan{Float64}
}}
    return true
end

MOI.supports(::Optimizer, ::MOI.VariableName, ::Type{MOI.VariableIndex}) = true
MOI.supports(::Optimizer, ::MOI.ConstraintName, ::Type{<:MOI.ConstraintIndex}) = true

MOI.supports(::Optimizer, ::MOI.Name) = true
MOI.supports(::Optimizer, ::MOI.Silent) = true
MOI.supports(::Optimizer, ::MOI.TimeLimitSec) = true
MOI.supports(::Optimizer, ::MOI.ObjectiveSense) = true
MOI.supports(::Optimizer, ::MOI.RawParameter) = true
MOI.supports(::Optimizer, ::MOI.ConstraintPrimalStart) = false
MOI.supports(::Optimizer, ::MOI.ConstraintDualStart) = false

function MOI.set(model::Optimizer, param::MOI.RawParameter, value)
    model.params[param.name] = value
    setparam!(model.inner, param.name, value)
    return
end

function MOI.get(model::Optimizer, param::MOI.RawParameter)
    return getparam(model.inner, param.name)
end

function MOI.set(model::Optimizer, ::MOI.TimeLimitSec, limit::Real)
    MOI.set(model, MOI.RawParameter("TimeLimit"), limit)
    return
end

function MOI.get(model::Optimizer, ::MOI.TimeLimitSec)
    return MOI.get(model, MOI.RawParameter("TimeLimit"))
end

MOI.Utilities.supports_default_copy_to(::Optimizer, ::Bool) = true

function MOI.copy_to(dest::Optimizer, src::MOI.ModelLike; kwargs...)
    return MOI.Utilities.automatic_copy_to(dest, src; kwargs...)
end

function MOI.get(model::Optimizer, ::MOI.ListOfVariableAttributesSet)
    return MOI.AbstractVariableAttribute[MOI.VariableName()]
end

function MOI.get(model::Optimizer, ::MOI.ListOfModelAttributesSet)
    attributes = Any[MOI.ObjectiveSense()]
    typ = MOI.get(model, MOI.ObjectiveFunctionType())
    if typ !== nothing
        push!(attributes, MOI.ObjectiveFunction{typ}())
    end
    if MOI.get(model, MOI.Name()) != ""
        push!(attributes, MOI.Name())
    end
    return attributes
end

function MOI.get(model::Optimizer, ::MOI.ListOfConstraintAttributesSet)
    return MOI.AbstractConstraintAttribute[MOI.ConstraintName()]
end

function _indices_and_coefficients(
    indices::AbstractVector{Int}, coefficients::AbstractVector{Float64},
    model::Optimizer, f::MOI.ScalarAffineFunction{Float64}
)
    i = 1
    for term in f.terms
        indices[i] = _info(model, term.variable_index).column
        coefficients[i] = term.coefficient
        i += 1
    end
    return indices, coefficients
end

function _indices_and_coefficients(
    model::Optimizer, f::MOI.ScalarAffineFunction{Float64}
)
    f_canon = MOI.Utilities.canonical(f)
    nnz = length(f_canon.terms)
    indices = Vector{Int}(undef, nnz)
    coefficients = Vector{Float64}(undef, nnz)
    _indices_and_coefficients(indices, coefficients, model, f_canon)
    return indices, coefficients
end

function _indices_and_coefficients(
    I::AbstractVector{Int}, J::AbstractVector{Int}, V::AbstractVector{Float64},
    indices::AbstractVector{Int}, coefficients::AbstractVector{Float64},
    model::Optimizer, f::MOI.ScalarQuadraticFunction
)
    for (i, term) in enumerate(f.quadratic_terms)
        I[i] = _info(model, term.variable_index_1).column
        J[i] = _info(model, term.variable_index_2).column
        V[i] =  term.coefficient
        # Gurobi returns a list of terms. MOI requires 0.5 x' Q x. So, to get
        # from
        #   Gurobi -> MOI => multiply diagonals by 2.0
        #   MOI -> Gurobi => multiply diagonals by 0.5
        # Example: 2x^2 + x*y + y^2
        #   |x y| * |a b| * |x| = |ax+by bx+cy| * |x| = 0.5ax^2 + bxy + 0.5cy^2
        #           |b c|   |y|                   |y|
        #   Gurobi needs: (I, J, V) = ([0, 0, 1], [0, 1, 1], [2, 1, 1])
        #   MOI needs:
        #     [SQT(4.0, x, x), SQT(1.0, x, y), SQT(2.0, y, y)]
        if I[i] == J[i]
            V[i] *= 0.5
        end
    end
    for (i, term) in enumerate(f.affine_terms)
        indices[i] = _info(model, term.variable_index).column
        coefficients[i] = term.coefficient
    end
    return
end

function _indices_and_coefficients(
    model::Optimizer, f::MOI.ScalarQuadraticFunction
)
    f_canon = MOI.Utilities.canonical(f)
    nnz_quadratic = length(f_canon.quadratic_terms)
    nnz_affine = length(f_canon.affine_terms)
    I = Vector{Int}(undef, nnz_quadratic)
    J = Vector{Int}(undef, nnz_quadratic)
    V = Vector{Float64}(undef, nnz_quadratic)
    indices = Vector{Int}(undef, nnz_affine)
    coefficients = Vector{Float64}(undef, nnz_affine)
    _indices_and_coefficients(I, J, V, indices, coefficients, model, f_canon)
    return indices, coefficients, I, J, V
end

_sense_and_rhs(s::MOI.LessThan{Float64}) = (Cchar('<'), s.upper)
_sense_and_rhs(s::MOI.GreaterThan{Float64}) = (Cchar('>'), s.lower)
_sense_and_rhs(s::MOI.EqualTo{Float64}) = (Cchar('='), s.value)

###
### Variables
###

# Short-cuts to return the VariableInfo associated with an index.
function _info(model::Optimizer, key::MOI.VariableIndex)
    if haskey(model.variable_info, key)
        return model.variable_info[key]
    end
    throw(MOI.InvalidIndex(key))
end

function _get_next_column(model::Optimizer)
    model.next_column += 1
    return model.next_column - 1
end

function MOI.add_variable(model::Optimizer)
    # Initialize `VariableInfo` with a dummy `VariableIndex` and a column,
    # because we need `add_item` to tell us what the `VariableIndex` is.
    index = CleverDicts.add_item(
        model.variable_info, VariableInfo(MOI.VariableIndex(0), 0)
    )
    info = _info(model, index)
    # Now, set `.index` and `.column`.
    info.index = index
    info.column = _get_next_column(model)
    add_cvar!(model.inner, 0.0)
    _require_update(model)
    return index
end

function MOI.add_variables(model::Optimizer, N::Int)
    add_cvars!(model.inner, zeros(N))
    indices = Vector{MOI.VariableIndex}(undef, N)
    for i in 1:N
        # Initialize `VariableInfo` with a dummy `VariableIndex` and a column,
        # because we need `add_item` to tell us what the `VariableIndex` is.
        index = CleverDicts.add_item(
            model.variable_info, VariableInfo(MOI.VariableIndex(0), 0)
        )
        info = _info(model, index)
        # Now, set `.index` and `.column`.
        info.index = index
        info.column = _get_next_column(model)
        indices[i] = index
    end
    _require_update(model)
    return indices
end

function MOI.is_valid(model::Optimizer, v::MOI.VariableIndex)
    return haskey(model.variable_info, v)
end

function MOI.delete(model::Optimizer, indices::Vector{<:MOI.VariableIndex})
    #_update_if_necessary(model)
    info = [_info(model, var_idx) for var_idx in indices]
    soc_idx = findfirst(e -> e.num_soc_constraints > 0, info)
    soc_idx !== nothing && throw(MOI.DeleteNotAllowed(indices[soc_idx]))
    del_cols = collect(i.column for i in info)
    del_vars!(model.inner, convert(Vector{Cint}, del_cols))
    for var_idx in indices
        delete!(model.variable_info, var_idx)
    end
    append!(model.columns_deleted_since_last_update, del_cols)
    model.name_to_variable = nothing
    # We throw away name_to_constraint_index so we will rebuild SingleVariable
    # constraint names without v.
    model.name_to_constraint_index = nothing
    _require_update(model)
    return
end

function MOI.delete(model::Optimizer, v::MOI.VariableIndex)
    #_update_if_necessary(model)
    info = _info(model, v)
    if info.num_soc_constraints > 0
        throw(MOI.DeleteNotAllowed(v))
    end
    push!(model.columns_deleted_since_last_update, info.column)
    del_vars!(model.inner, Cint[info.column])
    delete!(model.variable_info, v)
    model.name_to_variable = nothing
    # We throw away name_to_constraint_index so we will rebuild SingleVariable
    # constraint names without v.
    model.name_to_constraint_index = nothing
    _require_update(model)
    return
end

function MOI.get(model::Optimizer, ::Type{MOI.VariableIndex}, name::String)
    if model.name_to_variable === nothing
        _rebuild_name_to_variable(model)
    end
    if haskey(model.name_to_variable, name)
        variable = model.name_to_variable[name]
        if variable === nothing
            error("Duplicate variable name detected: $(name)")
        end
        return variable
    end
    return nothing
end

function _rebuild_name_to_variable(model::Optimizer)
    model.name_to_variable = Dict{String, Union{Nothing, MOI.VariableIndex}}()
    for (index, info) in model.variable_info
        if info.name == ""
            continue
        end
        if haskey(model.name_to_variable, info.name)
            model.name_to_variable[info.name] = nothing
        else
            model.name_to_variable[info.name] = index
        end
    end
    return
end

function MOI.get(model::Optimizer, ::MOI.VariableName, v::MOI.VariableIndex)
    return _info(model, v).name
end

function MOI.set(
    model::Optimizer, ::MOI.VariableName, v::MOI.VariableIndex, name::String
)
    info = _info(model, v)
    info.name = name
    set_strattrelement!(model.inner, "VarName", info.column, name)
    _require_update(model)
    model.name_to_variable = nothing
    return
end

###
### Objectives
###

function _zero_objective(model::Optimizer)
    num_vars = length(model.variable_info)
    obj = zeros(Float64, num_vars)
    _update_if_necessary(model)
    delq!(model.inner)
    set_dblattrarray!(model.inner, "Obj", 1, num_vars, obj)
    set_dblattr!(model.inner, "ObjCon", 0.0)
    _require_update(model)
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveSense, sense::MOI.OptimizationSense
)
    if sense == MOI.MIN_SENSE
        set_sense!(model.inner, :minimize)
        model.is_feasibility = false
    elseif sense == MOI.MAX_SENSE
        set_sense!(model.inner, :maximize)
        model.is_feasibility = false
    elseif sense == MOI.FEASIBILITY_SENSE
        _zero_objective(model)
        set_sense!(model.inner, :minimize)
        model.is_feasibility = true
    else
        error("Invalid objective sense: $(sense)")
    end
    _require_update(model)
    return
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveSense)
    _update_if_necessary(model)
    sense = model_sense(model.inner)
    if model.is_feasibility
        return MOI.FEASIBILITY_SENSE
    elseif sense == :maximize
        return MOI.MAX_SENSE
    elseif sense == :minimize
        return MOI.MIN_SENSE
    end
    error("Invalid objective sense: $(sense)")
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F
) where {F <: MOI.SingleVariable}
    MOI.set(
        model, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
        convert(MOI.ScalarAffineFunction{Float64}, f)
    )
    model.objective_type = SINGLE_VARIABLE
    return
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveFunction{MOI.SingleVariable})
    obj = MOI.get(model, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}())
    return convert(MOI.SingleVariable, obj)
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F
) where {F <: MOI.ScalarAffineFunction{Float64}}
    if model.objective_type == SCALAR_QUADRATIC
        # We need to zero out the existing quadratic objective.
        delq!(model.inner)
    end
    num_vars = length(model.variable_info)
    obj = zeros(Float64, num_vars)
    for term in f.terms
        column = _info(model, term.variable_index).column
        obj[column] += term.coefficient
    end
    # NOTE: variables added may be referred before a `_update_if_necessary`
    # what is the problem we try to prevent below?
    # This update is needed because we might have added some variables.
    _update_if_necessary(model)
    set_dblattrarray!(model.inner, "Obj", 1, num_vars, obj)
    set_dblattr!(model.inner, "ObjCon", f.constant)
    _require_update(model)
    model.objective_type = SCALAR_AFFINE
end

function MOI.get(
    model::Optimizer, ::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}
)
    if model.objective_type == SCALAR_QUADRATIC
        error("Unable to get objective function. Currently: $(model.objective_type).")
    end
    _update_if_necessary(model)
    dest = zeros(length(model.variable_info))
    get_dblattrarray!(dest, model.inner, "Obj", 1)
    terms = MOI.ScalarAffineTerm{Float64}[]
    for (index, info) in model.variable_info
        coefficient = dest[info.column]
        iszero(coefficient) && continue
        push!(terms, MOI.ScalarAffineTerm(coefficient, index))
    end
    constant = get_dblattr(model.inner, "ObjCon")
    return MOI.ScalarAffineFunction(terms, constant)
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F
) where {F <: MOI.ScalarQuadraticFunction{Float64}}
    affine_indices, affine_coefficients, I, J, V = _indices_and_coefficients(model, f)
    _update_if_necessary(model)
    # We need to zero out any existing linear objective.
    obj = zeros(length(model.variable_info))
    for (i, c) in zip(affine_indices, affine_coefficients)
        obj[i] = c
    end
    set_dblattrarray!(model.inner, "Obj", 1, length(obj), obj)
    set_dblattr!(model.inner, "ObjCon", f.constant)
    # We need to zero out the existing quadratic objective.
    delq!(model.inner)
    add_qpterms!(model.inner, I, J, V)
    _require_update(model)
    model.objective_type = SCALAR_QUADRATIC
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ObjectiveFunction{MOI.ScalarQuadraticFunction{Float64}}
)
    _update_if_necessary(model)
    dest = zeros(length(model.variable_info))
    get_dblattrarray!(dest, model.inner, "Obj", 1)
    terms = MOI.ScalarAffineTerm{Float64}[]
    for (index, info) in model.variable_info
        coefficient = dest[info.column]
        iszero(coefficient) && continue
        push!(terms, MOI.ScalarAffineTerm(coefficient, index))
    end
    constant = get_dblattr(model.inner, "ObjCon")
    q_terms = MOI.ScalarQuadraticTerm{Float64}[]
    I, J, V = getq(model.inner)
    for (i, j, v) in zip(I, J, V)
        iszero(v) && continue
        # See note in `_indices_and_coefficients`.
        new_v = i == j ? 2v : v
        push!(
            q_terms,
            MOI.ScalarQuadraticTerm(
                new_v,
                model.variable_info[CleverDicts.LinearIndex(i + 1)].index,
                model.variable_info[CleverDicts.LinearIndex(j + 1)].index
            )
        )
    end
    return MOI.ScalarQuadraticFunction(terms, q_terms, constant)
end

function MOI.modify(
    model::Optimizer,
    ::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}},
    chg::MOI.ScalarConstantChange{Float64}
)
    set_dblattr!(model.inner, "ObjCon", chg.new_constant)
    _require_update(model)
    return
end

##
##  SingleVariable-in-Set constraints.
##

function _info(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}
)
    var_index = MOI.VariableIndex(c.value)
    if haskey(model.variable_info, var_index)
        return _info(model, var_index)
    end
    return throw(MOI.InvalidIndex(c))
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    if haskey(model.variable_info, MOI.VariableIndex(c.value))
        info = _info(model, c)
        return info.bound == LESS_THAN || info.bound == LESS_AND_GREATER_THAN
    end
    return false
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    if haskey(model.variable_info, MOI.VariableIndex(c.value))
        info = _info(model, c)
        return info.bound == GREATER_THAN || info.bound == LESS_AND_GREATER_THAN
    end
    return false
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).bound == INTERVAL
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).bound == EQUAL_TO
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == BINARY
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == INTEGER
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == SEMICONTINUOUS
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == SEMIINTEGER
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}
)
    MOI.throw_if_not_valid(model, c)
    return MOI.SingleVariable(MOI.VariableIndex(c.value))
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}, ::MOI.SingleVariable
)
    return throw(MOI.SettingSingleVariableFunctionNotAllowed())
end

_bounds(s::MOI.GreaterThan{Float64}) = (s.lower, nothing)
_bounds(s::MOI.LessThan{Float64}) = (nothing, s.upper)
_bounds(s::MOI.EqualTo{Float64}) = (s.value, s.value)
_bounds(s::MOI.Interval{Float64}) = (s.lower, s.upper)

function _throw_if_existing_lower(
    bound::BoundType, var_type::VariableType, new_set::Type{<:MOI.AbstractSet},
    variable::MOI.VariableIndex
)
    existing_set = if bound == LESS_AND_GREATER_THAN || bound == GREATER_THAN
        MOI.GreaterThan{Float64}
    elseif bound == INTERVAL
        MOI.Interval{Float64}
    elseif bound == EQUAL_TO
        MOI.EqualTo{Float64}
    elseif var_type == SEMIINTEGER
        MOI.Semiinteger{Float64}
    elseif var_type == SEMICONTINUOUS
        MOI.Semicontinuous{Float64}
    else
        nothing  # Also covers `NONE` and `LESS_THAN`.
    end
    if existing_set !== nothing
        throw(MOI.LowerBoundAlreadySet{existing_set, new_set}(variable))
    end
end

function _throw_if_existing_upper(
    bound::BoundType, var_type::VariableType, new_set::Type{<:MOI.AbstractSet},
    variable::MOI.VariableIndex
)
    existing_set = if bound == LESS_AND_GREATER_THAN || bound == LESS_THAN
        MOI.LessThan{Float64}
    elseif bound == INTERVAL
        MOI.Interval{Float64}
    elseif bound == EQUAL_TO
        MOI.EqualTo{Float64}
    elseif var_type == SEMIINTEGER
        MOI.Semiinteger{Float64}
    elseif var_type == SEMICONTINUOUS
        MOI.Semicontinuous{Float64}
    else
        nothing  # Also covers `NONE` and `GREATER_THAN`.
    end
    if existing_set !== nothing
        throw(MOI.UpperBoundAlreadySet{existing_set, new_set}(variable))
    end
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, s::S
) where {S <: SCALAR_SETS}
    info = _info(model, f.variable)
    if S <: MOI.LessThan{Float64}
        _throw_if_existing_upper(info.bound, info.type, S, f.variable)
        info.bound = info.bound == GREATER_THAN ? LESS_AND_GREATER_THAN : LESS_THAN
        info.upper_bound_if_bounded = s.upper
    elseif S <: MOI.GreaterThan{Float64}
        _throw_if_existing_lower(info.bound, info.type, S, f.variable)
        info.bound = info.bound == LESS_THAN ? LESS_AND_GREATER_THAN : GREATER_THAN
        info.lower_bound_if_bounded = s.lower
    elseif S <: MOI.EqualTo{Float64}
        _throw_if_existing_lower(info.bound, info.type, S, f.variable)
        _throw_if_existing_upper(info.bound, info.type, S, f.variable)
        info.bound = EQUAL_TO
        info.upper_bound_if_bounded = info.lower_bound_if_bounded = s.value
    else
        @assert S <: MOI.Interval{Float64}
        _throw_if_existing_lower(info.bound, info.type, S, f.variable)
        _throw_if_existing_upper(info.bound, info.type, S, f.variable)
        info.bound = INTERVAL
        info.upper_bound_if_bounded = s.upper
        info.lower_bound_if_bounded = s.lower
    end
    index = MOI.ConstraintIndex{MOI.SingleVariable, typeof(s)}(f.variable.value)
    # This sets the bounds in the inner model and set the cache in VariableInfo
    # again (we could just set them there, but then VariableInfo is in a
    # invalid state that trigger some asserts, i.e., has bound but no cache).
    MOI.set(model, MOI.ConstraintSet(), index, s)
    return index
end

function MOI.add_constraints(
    model::Optimizer, f::Vector{MOI.SingleVariable}, s::Vector{S}
) where {S <: SCALAR_SETS}
    for (fi, si) in zip(f, s)
        info = _info(model, fi.variable)
        if S <: MOI.LessThan{Float64}
            _throw_if_existing_upper(info.bound, info.type, S, fi.variable)
            info.bound = info.bound == GREATER_THAN ? LESS_AND_GREATER_THAN : LESS_THAN
            info.upper_bound_if_bounded = si.upper
        elseif S <: MOI.GreaterThan{Float64}
            _throw_if_existing_lower(info.bound, info.type, S, fi.variable)
            info.bound = info.bound == LESS_THAN ? LESS_AND_GREATER_THAN : GREATER_THAN
            info.lower_bound_if_bounded = si.lower
        elseif S <: MOI.EqualTo{Float64}
            _throw_if_existing_lower(info.bound, info.type, S, fi.variable)
            _throw_if_existing_upper(info.bound, info.type, S, fi.variable)
            info.bound = EQUAL_TO
            info.upper_bound_if_bounded = info.lower_bound_if_bounded = si.value
        else
            @assert S <: MOI.Interval{Float64}
            _throw_if_existing_lower(info.bound, info.type, S, fi.variable)
            _throw_if_existing_upper(info.bound, info.type, S, fi.variable)
            info.bound = INTERVAL
            info.upper_bound_if_bounded = si.upper
            info.lower_bound_if_bounded = si.lower
        end
    end
    indices = [
        MOI.ConstraintIndex{MOI.SingleVariable, eltype(s)}(fi.variable.value)
        for fi in f
    ]
    _set_bounds(model, indices, s)
    return indices
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    set_dblattrelement!(model.inner, "UB", info.column, Inf)
    _require_update(model)
    if info.bound == LESS_AND_GREATER_THAN
        info.bound = GREATER_THAN
    else
        info.bound = NONE
    end
    info.upper_bound_if_bounded = NaN
    info.lessthan_name = ""
    model.name_to_constraint_index = nothing
    return
end

"""
    _set_variable_lower_bound(model, info, value)

This function is used to indirectly set the lower bound of a variable.

We need to do it this way to account for potential lower bounds of 0.0 added by
VectorOfVariables-in-SecondOrderCone constraints.

This does not look at `info.bound` and does not update
`info.lower_bound_if_bounded`.

See also `_get_variable_lower_bound`.
"""
function _set_variable_lower_bound(model, info, value)
    if info.num_soc_constraints == 0
        # No SOC constraints, set directly.
        @assert isnan(info.lower_bound_if_soc)
        set_dblattrelement!(model.inner, "LB", info.column, value)
        _require_update(model)
    elseif value >= 0.0
        # Regardless of whether there are SOC constraints, this is a valid bound
        # for the SOC constraint and should over-ride any previous bounds.
        info.lower_bound_if_soc = NaN
        set_dblattrelement!(model.inner, "LB", info.column, value)
        _require_update(model)
    elseif isnan(info.lower_bound_if_soc)
        # Previously, we had a non-negative lower bound (i.e., it was set in the
        # case above). Now we're setting this with a negative one, but there are
        # still some SOC constraints, so we cache `value` and set the variable
        # lower bound to `0.0`.
        @assert value < 0.0
        set_dblattrelement!(model.inner, "LB", info.column, 0.0)
        _require_update(model)
        info.lower_bound_if_soc = value
    else
        # Previously, we had a negative lower bound. We're setting this with
        # another negative one, but there are still some SOC constraints.
        @assert info.lower_bound_if_soc < 0.0
        info.lower_bound_if_soc = value
    end
end

"""
    _get_variable_lower_bound(model, info)

Get the current variable lower bound, ignoring a potential bound of `0.0` set
by a second order cone constraint, if an adequate `SingleVariable` constraint
is set (i.e., `info.bound` is not `NONE` or `LESS_THAN`) then use a cached
value; otherwise update the model if necessary and query the LB from it.

See also `_set_variable_lower_bound`.
"""
function _get_variable_lower_bound(model, info)
    if !isnan(info.lower_bound_if_soc)
        # There is a value stored. That means that we must have set a value that
        # was < 0.
        @assert info.lower_bound_if_soc < 0.0
        return info.lower_bound_if_soc
    elseif !isnan(info.lower_bound_if_bounded)
        @assert info.bound in (
            GREATER_THAN, LESS_AND_GREATER_THAN, EQUAL_TO, INTERVAL
        )
        return info.lower_bound_if_bounded
    end
    _update_if_necessary(model)
    return get_dblattrelement(model.inner, "LB", info.column)
end

"""
    _get_variable_upper_bound(model, info)

Get the current variable upper bound, if an adequate `SingleVariable`
constraint is set (i.e., `info.bound` is not `NONE` or `GREATER_THAN`) then use
a cached value; otherwise update the model if necessary and query the UB from
it.

See also `_get_variable_lower_bound`.
"""
function _get_variable_upper_bound(model, info)
    if !isnan(info.upper_bound_if_bounded)
        @assert info.bound in (
            LESS_THAN, LESS_AND_GREATER_THAN, EQUAL_TO, INTERVAL
        )
        return info.upper_bound_if_bounded
    end
    _update_if_necessary(model)
    return get_dblattrelement(model.inner, "UB", info.column)
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _set_variable_lower_bound(model, info, -Inf)
    if info.bound == LESS_AND_GREATER_THAN
        info.bound = LESS_THAN
    else
        info.bound = NONE
    end
    info.lower_bound_if_bounded = NaN
    info.greaterthan_interval_or_equalto_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _set_variable_lower_bound(model, info, -Inf)
    set_dblattrelement!(model.inner, "UB", info.column, Inf)
    _require_update(model)
    info.bound = NONE
    info.upper_bound_if_bounded = info.lower_bound_if_bounded = NaN
    info.greaterthan_interval_or_equalto_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _set_variable_lower_bound(model, info, -Inf)
    set_dblattrelement!(model.inner, "UB", info.column, Inf)
    _require_update(model)
    info.bound = NONE
    info.upper_bound_if_bounded = info.lower_bound_if_bounded = NaN
    info.greaterthan_interval_or_equalto_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    @assert !isnan(info.lower_bound_if_bounded)
    return MOI.GreaterThan(_get_variable_lower_bound(model, info))
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    @assert !isnan(info.upper_bound_if_bounded)
    return MOI.LessThan(_get_variable_upper_bound(model, info))
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    @assert !isnan(info.upper_bound_if_bounded)
    @assert info.upper_bound_if_bounded == info.lower_bound_if_bounded
    return MOI.EqualTo(_get_variable_lower_bound(model, info))
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    @assert !isnan(info.upper_bound_if_bounded)
    @assert !isnan(info.lower_bound_if_bounded)
    return MOI.Interval(
        _get_variable_lower_bound(model, info),
        _get_variable_upper_bound(model, info),
    )
end

function _set_bounds(
    model::Optimizer,
    indices::Vector{MOI.ConstraintIndex{MOI.SingleVariable, S}},
    sets::Vector{S}
) where {S}
    lower_columns, lower_values = Int[], Float64[]
    upper_columns, upper_values = Int[], Float64[]
    for (c, s) in zip(indices, sets)
        lower, upper = _bounds(s)
        info = _info(model, c)
        if lower !== nothing
            if info.num_soc_constraints == 0
                push!(lower_columns, info.column)
                push!(lower_values, lower)
            else
                _set_variable_lower_bound(model, info, lower)
            end
        end
        if upper !== nothing
            push!(upper_columns, info.column)
            push!(upper_values, upper)
        end
    end
    if length(lower_columns) > 0
        set_dblattrlist!(model.inner, "LB", lower_columns, lower_values)
    end
    if length(upper_columns) > 0
        set_dblattrlist!(model.inner, "UB", upper_columns, upper_values)
    end
    _require_update(model)
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}, s::S
) where {S<:SCALAR_SETS}
    MOI.throw_if_not_valid(model, c)
    lower, upper = _bounds(s)
    info = _info(model, c)
    if lower !== nothing
        @assert !isnan(info.lower_bound_if_bounded)
        info.lower_bound_if_bounded = lower
        _set_variable_lower_bound(model, info, lower)
    end
    if upper !== nothing
        @assert !isnan(info.upper_bound_if_bounded)
        info.upper_bound_if_bounded = upper
        set_dblattrelement!(model.inner, "UB", info.column, upper)
    end
    _require_update(model)
    return
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, ::MOI.ZeroOne
)
    info = _info(model, f.variable)
    set_charattrelement!(model.inner, "VType", info.column, Char('B'))
    _require_update(model)
    info.type = BINARY
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}(f.variable.value)
end

function MOI.delete(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    set_charattrelement!(model.inner, "VType", info.column, Char('C'))
    _require_update(model)
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}
)
    MOI.throw_if_not_valid(model, c)
    return MOI.ZeroOne()
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, ::MOI.Integer
)
    info = _info(model, f.variable)
    set_charattrelement!(model.inner, "VType", info.column, Char('I'))
    _require_update(model)
    info.type = INTEGER
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}(f.variable.value)
end

function MOI.delete(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    set_charattrelement!(model.inner, "VType", info.column, Char('C'))
    _require_update(model)
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}
)
    MOI.throw_if_not_valid(model, c)
    return MOI.Integer()
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, s::MOI.Semicontinuous{Float64}
)
    info = _info(model, f.variable)
    _throw_if_existing_lower(info.bound, info.type, typeof(s), f.variable)
    _throw_if_existing_upper(info.bound, info.type, typeof(s), f.variable)
    set_charattrelement!(model.inner, "VType", info.column, Char('S'))
    _set_variable_lower_bound(model, info, s.lower)
    set_dblattrelement!(model.inner, "UB", info.column, s.upper)
    _require_update(model)
    info.type = SEMICONTINUOUS
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}(f.variable.value)
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    set_charattrelement!(model.inner, "VType", info.column, Char('C'))
    _set_variable_lower_bound(model, info, -Inf)
    set_dblattrelement!(model.inner, "UB", info.column, Inf)
    _require_update(model)
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _update_if_necessary(model)
    lower = _get_variable_lower_bound(model, info)
    upper = get_dblattrelement(model.inner, "UB", info.column)
    return MOI.Semicontinuous(lower, upper)
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, s::MOI.Semiinteger{Float64}
)
    info = _info(model, f.variable)
    _throw_if_existing_lower(info.bound, info.type, typeof(s), f.variable)
    _throw_if_existing_upper(info.bound, info.type, typeof(s), f.variable)
    set_charattrelement!(model.inner, "VType", info.column, Char('N'))
    _set_variable_lower_bound(model, info, s.lower)
    set_dblattrelement!(model.inner, "UB", info.column, s.upper)
    _require_update(model)
    info.type = SEMIINTEGER
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}(f.variable.value)
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    set_charattrelement!(model.inner, "VType", info.column, Char('C'))
    _set_variable_lower_bound(model, info, -Inf)
    set_dblattrelement!(model.inner, "UB", info.column, Inf)
    _require_update(model)
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _update_if_necessary(model)
    lower = _get_variable_lower_bound(model, info)
    upper = get_dblattrelement(model.inner, "UB", info.column)
    return MOI.Semiinteger(lower, upper)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}
) where {S}
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    if S <: MOI.LessThan
        return info.lessthan_name
    elseif S <: Union{MOI.GreaterThan, MOI.Interval, MOI.EqualTo}
        return info.greaterthan_interval_or_equalto_name
    else
        @assert S <: Union{MOI.ZeroOne, MOI.Integer, MOI.Semiinteger, MOI.Semicontinuous}
        return info.type_constraint_name
    end
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}, name::String
) where {S}
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    old_name = ""
    if S <: MOI.LessThan
        old_name = info.lessthan_name
        info.lessthan_name = name
    elseif S <: Union{MOI.GreaterThan, MOI.Interval, MOI.EqualTo}
        old_name = info.greaterthan_interval_or_equalto_name
        info.greaterthan_interval_or_equalto_name = name
    else
        @assert S <: Union{MOI.ZeroOne, MOI.Integer, MOI.Semiinteger, MOI.Semicontinuous}
        info.type_constraint_name
        info.type_constraint_name = name
    end
    model.name_to_constraint_index = nothing
    return
end

###
### ScalarAffineFunction-in-Set
###

function _info(
    model::Optimizer,
    key::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    if haskey(model.affine_constraint_info, key.value)
        return model.affine_constraint_info[key.value]
    end
    throw(MOI.InvalidIndex(key))
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    info = get(model.affine_constraint_info, c.value, nothing)
    if info === nothing
        return false
    else
        return typeof(info.set) == S
    end
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.ScalarAffineFunction{Float64},
    s::Union{MOI.GreaterThan{Float64}, MOI.LessThan{Float64}, MOI.EqualTo{Float64}}
)
    if !iszero(f.constant)
        throw(MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(f.constant))
    end
    model.last_constraint_index += 1
    model.affine_constraint_info[model.last_constraint_index] =
        ConstraintInfo(length(model.affine_constraint_info) + 1, s)

    indices, coefficients = _indices_and_coefficients(model, f)
    sense, rhs = _sense_and_rhs(s)
    add_constr!(model.inner, indices, coefficients, sense, rhs)
    _require_update(model)
    return MOI.ConstraintIndex{typeof(f), typeof(s)}(model.last_constraint_index)
end

function MOI.add_constraints(
    model::Optimizer, f::Vector{MOI.ScalarAffineFunction{Float64}},
    s::Vector{<:Union{MOI.GreaterThan{Float64}, MOI.LessThan{Float64}, MOI.EqualTo{Float64}}}
)
    if length(f) != length(s)
        error("Number of functions does not equal number of sets.")
    end
    canonicalized_functions = MOI.Utilities.canonical.(f)
    # First pass: compute number of non-zeros to allocate space.
    nnz = 0
    for fi in canonicalized_functions
        if !iszero(fi.constant)
            throw(MOI.ScalarFunctionConstantNotZero{Float64, eltype(f), eltype(s)}(fi.constant))
        end
        nnz += length(fi.terms)
    end
    # Initialize storage
    indices = Vector{MOI.ConstraintIndex{eltype(f), eltype(s)}}(undef, length(f))
    row_starts = Vector{Int}(undef, length(f) + 1)
    row_starts[1] = 1
    columns = Vector{Int}(undef, nnz)
    coefficients = Vector{Float64}(undef, nnz)
    senses = Vector{Cchar}(undef, length(f))
    rhss = Vector{Float64}(undef, length(f))
    # Second pass: loop through, passing views to _indices_and_coefficients.
    for (i, (fi, si)) in enumerate(zip(canonicalized_functions, s))
        senses[i], rhss[i] = _sense_and_rhs(si)
        row_starts[i + 1] = row_starts[i] + length(fi.terms)
        _indices_and_coefficients(
            view(columns, row_starts[i]:row_starts[i + 1] - 1),
            view(coefficients, row_starts[i]:row_starts[i + 1] - 1),
            model, fi
        )
        model.last_constraint_index += 1
        indices[i] = MOI.ConstraintIndex{eltype(f), eltype(s)}(model.last_constraint_index)
        model.affine_constraint_info[model.last_constraint_index] =
            ConstraintInfo(length(model.affine_constraint_info) + 1, si)
    end
    pop!(row_starts)  # Gurobi doesn't need the final row start.
    add_constrs!(model.inner, row_starts, columns, coefficients, senses, rhss)
    _require_update(model)
    return indices
end

function MOI.delete(
    model::Optimizer,
    cs::Vector{<:MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}}
)
    # The `sort!`s called are necessary for improving the efficiency of the
    # updates (i.e., without them we cannot use `searchsorted*` methods).
    _update_if_necessary(model)
    rows_to_delete = sort!(getfield.(_info.(model, cs), :row))
    del_constrs!(model.inner, rows_to_delete)
    _require_update(model)
    for (_, info) in model.affine_constraint_info
        # The trick here is: searchsortedlast returns, in O(log n), the
        # last index with a row smaller than info.row, over rows_to_delete
        # this is the same as the number of rows deleted before it, and
        # how much its value need to be shifted.
        info.row -= searchsortedlast(rows_to_delete, info.row)
    end
    cs_values = sort!(getfield.(cs, :value))
    # If the key of an model.affine_constraint_info entry is in cs_values,
    # then that entry is deleted.
    filter!(model.affine_constraint_info) do pair
        isempty(searchsorted(cs_values, pair.first))
    end
    model.name_to_constraint_index = nothing
    return
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    row = _info(model, c).row
    _update_if_necessary(model)
    del_constrs!(model.inner, row)
    _require_update(model)
    for (key, info) in model.affine_constraint_info
        if info.row > row
            info.row -= 1
        end
    end
    delete!(model.affine_constraint_info, c.value)
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    _update_if_necessary(model)
    rhs = get_dblattrelement(model.inner, "RHS", _info(model, c).row)
    return S(rhs)
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}, s::S
) where {S}
    set_dblattrelement!(model.inner, "RHS", _info(model, c).row, MOI.constant(s))
    _require_update(model)
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    _update_if_necessary(model)
    sparse_a = SparseArrays.sparse(get_constrs(model.inner, _info(model, c).row, 1)')
    terms = MOI.ScalarAffineTerm{Float64}[]
    for (col, val) in zip(sparse_a.rowval, sparse_a.nzval)
        iszero(val) && continue
        push!(
            terms,
            MOI.ScalarAffineTerm(
                val,
                model.variable_info[CleverDicts.LinearIndex(col)].index
            )
        )
    end
    return MOI.ScalarAffineFunction(terms, 0.0)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any},
    name::String
)
    info = _info(model, c)
    info.name = name
    if !isempty(name)
        set_strattrelement!(model.inner, "ConstrName", info.row, name)
        _require_update(model)
    end
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(model::Optimizer, ::Type{MOI.ConstraintIndex}, name::String)
    if model.name_to_constraint_index === nothing
        _rebuild_name_to_constraint_index(model)
    end
    if haskey(model.name_to_constraint_index, name)
        constr = model.name_to_constraint_index[name]
        if constr === nothing
            error("Duplicate constraint name detected: $(name)")
        end
        return constr
    end
    return nothing
end

function MOI.get(
    model::Optimizer, C::Type{MOI.ConstraintIndex{F, S}}, name::String
) where {F, S}
    index = MOI.get(model, MOI.ConstraintIndex, name)
    if typeof(index) == C
        return index::MOI.ConstraintIndex{F, S}
    end
    return nothing
end

function _rebuild_name_to_constraint_index(model::Optimizer)
    model.name_to_constraint_index = Dict{String, Union{Nothing, MOI.ConstraintIndex}}()
    _rebuild_name_to_constraint_index_util(
        model, model.affine_constraint_info, MOI.ScalarAffineFunction{Float64}
    )
    _rebuild_name_to_constraint_index_util(
        model, model.quadratic_constraint_info, MOI.ScalarQuadraticFunction{Float64}
    )
    _rebuild_name_to_constraint_index_util(
        model, model.sos_constraint_info, MOI.VectorOfVariables
    )
    _rebuild_name_to_constraint_index_variables(model)
    return
end

function _rebuild_name_to_constraint_index_util(model::Optimizer, dict, F)
    for (index, info) in dict
        if info.name == ""
            continue
        elseif haskey(model.name_to_constraint_index, info.name)
            model.name_to_constraint_index[info.name] = nothing
        else
            model.name_to_constraint_index[info.name] =
                MOI.ConstraintIndex{F, typeof(info.set)}(index)
        end
    end
    return
end

function _rebuild_name_to_constraint_index_variables(model::Optimizer)
    for (key, info) in model.variable_info
        for S in (
            MOI.LessThan{Float64}, MOI.GreaterThan{Float64},
            MOI.EqualTo{Float64}, MOI.Interval{Float64}, MOI.ZeroOne,
            MOI.Integer, MOI.Semicontinuous{Float64}, MOI.Semiinteger{Float64}
        )
            constraint_name = ""
            if info.bound in _bound_enums(S)
                constraint_name = S == MOI.LessThan{Float64} ?
                    info.lessthan_name : info.greaterthan_interval_or_equalto_name
            elseif info.type in _type_enums(S)
                constraint_name = info.type_constraint_name
            end
            if constraint_name == ""
                continue
            elseif haskey(model.name_to_constraint_index, constraint_name)
                model.name_to_constraint_index[constraint_name] = nothing
            else
                model.name_to_constraint_index[constraint_name] =
                    MOI.ConstraintIndex{MOI.SingleVariable, S}(key.value)
            end
        end
    end
    return
end

###
### ScalarQuadraticFunction-in-SCALAR_SET
###

function _info(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    if haskey(model.quadratic_constraint_info, c.value)
        return model.quadratic_constraint_info[c.value]
    end
    throw(MOI.InvalidIndex(c))
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.ScalarQuadraticFunction{Float64}, s::SCALAR_SETS
)
    if !iszero(f.constant)
        throw(MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(f.constant))
    end
    indices, coefficients, I, J, V = _indices_and_coefficients(model, f)
    sense, rhs = _sense_and_rhs(s)
    add_qconstr!(model.inner, indices, coefficients, I, J, V, sense, rhs)
    _require_update(model)
    model.last_constraint_index += 1
    model.quadratic_constraint_info[model.last_constraint_index] =
        ConstraintInfo(length(model.quadratic_constraint_info) + 1, s)
    return MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, typeof(s)}(model.last_constraint_index)
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    info = get(model.quadratic_constraint_info, c.value, nothing)
    return info !== nothing && typeof(info.set) == S
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    _update_if_necessary(model)
    info = _info(model, c)
    delqconstrs!(model.inner, [info.row])
    _require_update(model)
    for (key, info_2) in model.quadratic_constraint_info
        if info_2.row > info.row
            info_2.row -= 1
        end
    end
    delete!(model.quadratic_constraint_info, c.value)
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    _update_if_necessary(model)
    rhs = get_dblattrelement(model.inner, "QCRHS", _info(model, c).row)
    return S(rhs)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    _update_if_necessary(model)
    affine_cols, affine_coefficients, I, J, V = getqconstr(model.inner, _info(model, c).row)
    affine_terms = MOI.ScalarAffineTerm{Float64}[]
    for (col, coef) in zip(affine_cols, affine_coefficients)
        iszero(coef) && continue
        push!(
            affine_terms,
            MOI.ScalarAffineTerm(
                coef,
                model.variable_info[CleverDicts.LinearIndex(col + 1)].index
                )
        )
    end
    quadratic_terms = MOI.ScalarQuadraticTerm{Float64}[]
    for (i, j, coef) in zip(I, J, V)
        new_coef = i == j ? 2coef : coef
        push!(
            quadratic_terms,
            MOI.ScalarQuadraticTerm(
                new_coef,
                model.variable_info[CleverDicts.LinearIndex(i + 1)].index,
                model.variable_info[CleverDicts.LinearIndex(j + 1)].index
            )
        )
    end
    return MOI.ScalarQuadraticFunction(affine_terms, quadratic_terms, 0.0)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S},
    name::String
) where {S}
    info = _info(model, c)
    info.name = name
    _update_if_necessary(model)
    set_strattrelement!(model.inner, "QCName", info.row, name)
    _require_update(model)
    model.name_to_constraint_index = nothing
    return
end

###
### VectorOfVariables-in-SOS{I|II}
###

const SOS = Union{MOI.SOS1{Float64}, MOI.SOS2{Float64}}

function _info(
    model::Optimizer,
    key::MOI.ConstraintIndex{MOI.VectorOfVariables, <:SOS}
)
    if haskey(model.sos_constraint_info, key.value)
        return model.sos_constraint_info[key.value]
    end
    throw(MOI.InvalidIndex(key))
end

_sos_type(::MOI.SOS1) = :SOS1
_sos_type(::MOI.SOS2) = :SOS2

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, S}
) where {S}
    info = get(model.sos_constraint_info, c.value, nothing)
    if info === nothing || typeof(info.set) != S
        return false
    end
    f = MOI.get(model, MOI.ConstraintFunction(), c)
    return all(MOI.is_valid.(model, f.variables))
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.VectorOfVariables, s::SOS
)
    columns = Int[_info(model, v).column for v in f.variables]
    add_sos!(model.inner, _sos_type(s), columns, s.weights)
    model.last_constraint_index += 1
    index = MOI.ConstraintIndex{MOI.VectorOfVariables, typeof(s)}(model.last_constraint_index)
    model.sos_constraint_info[index.value] = ConstraintInfo(
        length(model.sos_constraint_info) + 1, s
    )
    _require_update(model)
    return index
end

function MOI.delete(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.VectorOfVariables, <:SOS}
)
    row = _info(model, c).row
    _update_if_necessary(model)
    del_sos!(model.inner, [Cint(row)])
    _require_update(model)
    for (key, info) in model.sos_constraint_info
        if info.row > row
            info.row -= 1
        end
    end
    delete!(model.sos_constraint_info, c.value)
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, <:Any}
)
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, <:Any}, name::String
)
    info = _info(model, c)
    info.name = name
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, S}
) where {S <: SOS}
    _update_if_necessary(model)
    sparse_a, _ = get_sos(model.inner, _info(model, c).row, 1)
    return S(sparse_a.nzval)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, S}
) where {S <: SOS}
    _update_if_necessary(model)
    sparse_a, _ = get_sos(model.inner, _info(model, c).row, 1)
    indices = SparseArrays.nonzeroinds(sparse_a[1, :])
    return MOI.VectorOfVariables(
        [model.variable_info[CleverDicts.LinearIndex(i)].index for i in indices]
    )
end

###
### Optimize methods.
###

function check_moi_callback_validity(model::Optimizer)
    has_moi_callback =
        model.lazy_callback !== nothing ||
        model.user_cut_callback !== nothing ||
        model.heuristic_callback !== nothing
    if has_moi_callback && model.has_generic_callback
        error("Cannot use Gurobi.CallbackFunction as well as MOI.AbstractCallbackFunction")
    end
    return has_moi_callback
end

function MOI.optimize!(model::Optimizer)
    # Note: although Gurobi will call update regardless, we do it now so that
    # the appropriate `needs_update` flag is set.
    _update_if_necessary(model)

    # Initialize callbacks if necessary.
    if check_moi_callback_validity(model)
        MOI.set(model, CallbackFunction(), default_moi_callback(model))
        model.has_generic_callback = false
    end

    optimize(model.inner)

    # Post-optimize caching to speed up the checks in VariablePrimal and
    # ConstraintDual.
    model.has_infeasibility_cert =
        MOI.get(model, MOI.DualStatus()) == MOI.INFEASIBILITY_CERTIFICATE
    model.has_unbounded_ray =
        MOI.get(model, MOI.PrimalStatus()) == MOI.INFEASIBILITY_CERTIFICATE

    return
end

function _throw_if_optimize_in_progress(model, attr)
    if model.callback_state != CB_NONE
        throw(MOI.OptimizeInProgress(attr))
    end
end

# These strings are taken directly from the following page of the online Gurobi
# documentation: https://www.com/documentation/8.1/refman/optimization_status_codes.html#sec:StatusCodes
const RAW_STATUS_STRINGS = [
    (MOI.OPTIMIZE_NOT_CALLED, "Model is loaded, but no solution information is available."),
    (MOI.OPTIMAL, "Model was solved to optimality (subject to tolerances), and an optimal solution is available."),
    (MOI.INFEASIBLE, "Model was proven to be infeasible."),
    (MOI.INFEASIBLE_OR_UNBOUNDED, "Model was proven to be either infeasible or unbounded. To obtain a more definitive conclusion, set the DualReductions parameter to 0 and reoptimize."),
    (MOI.DUAL_INFEASIBLE, "Model was proven to be unbounded. Important note: an unbounded status indicates the presence of an unbounded ray that allows the objective to improve without limit. It says nothing about whether the model has a feasible solution. If you require information on feasibility, you should set the objective to zero and reoptimize."),
    (MOI.OBJECTIVE_LIMIT, "Optimal objective for model was proven to be worse than the value specified in the Cutoff parameter. No solution information is available."),
    (MOI.ITERATION_LIMIT, "Optimization terminated because the total number of simplex iterations performed exceeded the value specified in the IterationLimit parameter, or because the total number of barrier iterations exceeded the value specified in the BarIterLimit parameter."),
    (MOI.NODE_LIMIT, "Optimization terminated because the total number of branch-and-cut nodes explored exceeded the value specified in the NodeLimit parameter."),
    (MOI.TIME_LIMIT, "Optimization terminated because the time expended exceeded the value specified in the TimeLimit parameter."),
    (MOI.SOLUTION_LIMIT, "Optimization terminated because the number of solutions found reached the value specified in the SolutionLimit parameter."),
    (MOI.INTERRUPTED, "Optimization was terminated by the user."),
    (MOI.NUMERICAL_ERROR, "Optimization was terminated due to unrecoverable numerical difficulties."),
    (MOI.OTHER_LIMIT, "Unable to satisfy optimality tolerances; a sub-optimal solution is available."),
    (MOI.OTHER_ERROR, "An asynchronous optimization call was made, but the associated optimization run is not yet complete."),
    (MOI.OBJECTIVE_LIMIT, "User specified an objective limit (a bound on either the best objective or the best bound), and that limit has been reached.")
]

function MOI.get(model::Optimizer, attr::MOI.RawStatusString)
    _throw_if_optimize_in_progress(model, attr)
    status_code = get_status_code(model.inner)
    if 1 <= status_code <= length(RAW_STATUS_STRINGS)
        return RAW_STATUS_STRINGS[status_code][2]
    end
    return MOI.OTHER_ERROR
end

function MOI.get(model::Optimizer, attr::MOI.TerminationStatus)
    _throw_if_optimize_in_progress(model, attr)
    status_code = get_status_code(model.inner)
    if 1 <= status_code <= length(RAW_STATUS_STRINGS)
        return RAW_STATUS_STRINGS[status_code][1]
    end
    return MOI.OTHER_ERROR
end

function MOI.get(model::Optimizer, attr::MOI.PrimalStatus)
    _throw_if_optimize_in_progress(model, attr)
    if attr.N != 1
        return MOI.NO_SOLUTION
    end
    stat = get_status(model.inner)
    if stat == :optimal
        return MOI.FEASIBLE_POINT
    elseif stat == :solution_limit
        return MOI.FEASIBLE_POINT
    elseif (stat == :inf_or_unbd || stat == :unbounded) && _has_primal_ray(model)
        return MOI.INFEASIBILITY_CERTIFICATE
    elseif stat == :suboptimal
        return MOI.FEASIBLE_POINT
    elseif is_mip(model.inner) && get_sol_count(model.inner) > 0
        return MOI.FEASIBLE_POINT
    end
    return MOI.NO_SOLUTION
end

function _has_dual_ray(model::Optimizer)
    try
        # Note: for performance reasons, we try to get 1 element because for
        # some versions of Gurobi, we cannot query 0 elements without error.
        get_dblattrarray(model.inner, "FarkasDual", 1, 1)
        return true
    catch ex
        if isa(ex, GurobiError)
            return false
        else
            rethrow(ex)
        end
    end
end

function MOI.get(model::Optimizer, attr::MOI.DualStatus)
    _throw_if_optimize_in_progress(model, attr)
    if attr.N != 1
        return MOI.NO_SOLUTION
    end
    stat = get_status(model.inner)
    if is_mip(model.inner)
        return MOI.NO_SOLUTION
    elseif is_qcp(model.inner) && MOI.get(model, MOI.RawParameter("QCPDual")) != 1
        return MOI.NO_SOLUTION
    elseif stat == :optimal
        return MOI.FEASIBLE_POINT
    elseif stat == :solution_limit
        return MOI.FEASIBLE_POINT
    elseif (stat == :inf_or_unbd || stat == :infeasible) && _has_dual_ray(model)
        return MOI.INFEASIBILITY_CERTIFICATE
    elseif stat == :suboptimal
        return MOI.FEASIBLE_POINT
    end
    return MOI.NO_SOLUTION
end

function _has_primal_ray(model::Optimizer)
    try
        # Note: for performance reasons, we try to get 1 element because for
        # some versions of Gurobi, we cannot query 0 elements without error.
        get_dblattrarray(model.inner, "UnbdRay", 1, 1)
        return true
    catch ex
        if isa(ex, GurobiError)
            return false
        else
            rethrow(ex)
        end
    end
end

function MOI.get(model::Optimizer, attr::MOI.VariablePrimal, x::MOI.VariableIndex)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    if model.has_unbounded_ray
        return get_dblattrelement(model.inner, "UnbdRay", _info(model, x).column)
    else
        return get_dblattrelement(model.inner, "X", _info(model, x).column)
    end
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    return MOI.get(model, MOI.VariablePrimal(), MOI.VariableIndex(c.value))
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    row = _info(model, c).row
    _update_if_necessary(model)
    rhs = get_dblattrelement(model.inner, "RHS", row)
    slack = get_dblattrelement(model.inner, "Slack", row)
    return rhs - slack
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, <:Any}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    row = _info(model, c).row
    _update_if_necessary(model)
    rhs = get_dblattrelement(model.inner, "QCRHS", row)
    slack = get_dblattrelement(model.inner, "QCSlack", row)
    return rhs - slack
end

function _dual_multiplier(model::Optimizer)
    return MOI.get(model, MOI.ObjectiveSense()) == MOI.MIN_SENSE ? 1.0 : -1.0
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    reduced_cost = get_dblattrelement(model.inner, "RC", _info(model, c).column)
    sense = MOI.get(model, MOI.ObjectiveSense())
    # The following is a heuristic for determining whether the reduced cost
    # applies to the lower or upper bound. It can be wrong by at most
    # `FeasibilityTol`.
    if sense == MOI.MIN_SENSE && reduced_cost < 0
        # If minimizing, the reduced cost must be negative (ignoring
        # tolerances).
        return reduced_cost
    elseif sense == MOI.MAX_SENSE && reduced_cost > 0
        # If minimizing, the reduced cost must be positive (ignoring
        # tolerances). However, because of the MOI dual convention, we return a
        # negative value.
        return -reduced_cost
    else
        # The reduced cost, if non-zero, must related to the lower bound.
        return 0.0
    end
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    reduced_cost = get_dblattrelement(model.inner, "RC", _info(model, c).column)
    sense = MOI.get(model, MOI.ObjectiveSense())
    # The following is a heuristic for determining whether the reduced cost
    # applies to the lower or upper bound. It can be wrong by at most
    # `FeasibilityTol`.
    if sense == MOI.MIN_SENSE && reduced_cost > 0
        # If minimizing, the reduced cost must be negative (ignoring
        # tolerances).
        return reduced_cost
    elseif sense == MOI.MAX_SENSE && reduced_cost < 0
        # If minimizing, the reduced cost must be positive (ignoring
        # tolerances). However, because of the MOI dual convention, we return a
        # negative value.
        return -reduced_cost
    else
        # The reduced cost, if non-zero, must related to the lower bound.
        return 0.0
    end
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    return _dual_multiplier(model) * get_dblattrelement(model.inner, "RC", _info(model, c).column)
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    return _dual_multiplier(model) * get_dblattrelement(model.inner, "RC", _info(model, c).column)
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    if model.has_infeasibility_cert
        return -_dual_multiplier(model) * get_dblattrelement(model.inner, "FarkasDual", _info(model, c).row)
    end
    return _dual_multiplier(model) * get_dblattrelement(model.inner, "Pi", _info(model, c).row)
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, <:Any}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    return _dual_multiplier(model) * get_dblattrelement(model.inner, "QCPi", _info(model, c).row)
end

function MOI.get(model::Optimizer, attr::MOI.ObjectiveValue)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    return get_dblattr(model.inner, "ObjVal")
end

function MOI.get(model::Optimizer, attr::MOI.ObjectiveBound)
    _throw_if_optimize_in_progress(model, attr)
    return get_dblattr(model.inner, "ObjBound")
end

function MOI.get(model::Optimizer, attr::MOI.SolveTime)
    _throw_if_optimize_in_progress(model, attr)
    return get_dblattr(model.inner, "RunTime")
end

function MOI.get(model::Optimizer, attr::MOI.SimplexIterations)
    _throw_if_optimize_in_progress(model, attr)
    return get_dblattr(model.inner, "IterCount")
end

function MOI.get(model::Optimizer, attr::MOI.BarrierIterations)
    _throw_if_optimize_in_progress(model, attr)
    return get_intattr(model.inner, "BarIterCount")
end

function MOI.get(model::Optimizer, attr::MOI.NodeCount)
    _throw_if_optimize_in_progress(model, attr)
    return get_dblattr(model.inner, "NodeCount")
end

function MOI.get(model::Optimizer, attr::MOI.RelativeGap)
    _throw_if_optimize_in_progress(model, attr)
    return get_dblattr(model.inner, "MIPGap")
end

function MOI.get(model::Optimizer, attr::MOI.DualObjectiveValue)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    return get_dblattr(model.inner, "ObjBound")
end

function MOI.get(model::Optimizer, attr::MOI.ResultCount)
    _throw_if_optimize_in_progress(model, attr)
    if model.has_infeasibility_cert || model.has_unbounded_ray
        return 1
    end
    return get_intattr(model.inner, "SolCount")
end

function MOI.get(model::Optimizer, ::MOI.Silent)
    return model.silent
end

function MOI.set(model::Optimizer, ::MOI.Silent, flag::Bool)
    model.silent = flag
    output_flag = flag ? 0 : get(model.params, "OutputFlag", 1)
    setparam!(model.inner, "OutputFlag", output_flag)
    return
end

function MOI.get(model::Optimizer, ::MOI.Name)
    _update_if_necessary(model)
    return get_strattr(model.inner, "ModelName")
end

function MOI.set(model::Optimizer, ::MOI.Name, name::String)
    set_strattr!(model.inner, "ModelName", name)
    _require_update(model)
    return
end

MOI.get(model::Optimizer, ::MOI.NumberOfVariables) = length(model.variable_info)
function MOI.get(model::Optimizer, ::MOI.ListOfVariableIndices)
    return sort!(collect(keys(model.variable_info)), by = x -> x.value)
end

MOI.get(model::Optimizer, ::MOI.RawSolver) = model.inner

function MOI.set(
    model::Optimizer, ::MOI.VariablePrimalStart, x::MOI.VariableIndex,
    value::Union{Nothing, Float64}
)
    info = _info(model, x)
    info.start = value
    grb_value = value !== nothing ? value : GRB_UNDEFINED
    set_dblattrelement!(model.inner, "Start", info.column, grb_value)
    _require_update(model)
    return
end

function MOI.get(
    model::Optimizer, ::MOI.VariablePrimalStart, x::MOI.VariableIndex
)
    return _info(model, x).start
end

function MOI.supports(
    ::Gurobi.Optimizer, ::MOI.VariablePrimalStart, ::Type{MOI.VariableIndex})
    return true
end

function MOI.get(model::Optimizer, ::MOI.NumberOfConstraints{F, S}) where {F, S}
    # TODO: this could be more efficient.
    return length(MOI.get(model, MOI.ListOfConstraintIndices{F, S}()))
end

_bound_enums(::Type{<:MOI.LessThan}) = (LESS_THAN, LESS_AND_GREATER_THAN)
_bound_enums(::Type{<:MOI.GreaterThan}) = (GREATER_THAN, LESS_AND_GREATER_THAN)
_bound_enums(::Type{<:MOI.Interval}) = (INTERVAL,)
_bound_enums(::Type{<:MOI.EqualTo}) = (EQUAL_TO,)
_bound_enums(::Any) = (nothing,)

_type_enums(::Type{MOI.ZeroOne}) = (BINARY,)
_type_enums(::Type{MOI.Integer}) = (INTEGER,)
_type_enums(::Type{<:MOI.Semicontinuous}) = (SEMICONTINUOUS,)
_type_enums(::Type{<:MOI.Semiinteger}) = (SEMIINTEGER,)
_type_enums(::Any) = (nothing,)

function MOI.get(
    model::Optimizer, ::MOI.ListOfConstraintIndices{MOI.SingleVariable, S}
) where {S}
    indices = MOI.ConstraintIndex{MOI.SingleVariable, S}[]
    for (key, info) in model.variable_info
        if info.bound in _bound_enums(S) || info.type in _type_enums(S)
            push!(indices, MOI.ConstraintIndex{MOI.SingleVariable, S}(key.value))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    indices = MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}[]
    for (key, info) in model.affine_constraint_info
        if typeof(info.set) == S
            push!(indices, MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}(key))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    indices = MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}[]
    for (key, info) in model.quadratic_constraint_info
        if typeof(info.set) == S
            push!(indices, MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}(key))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer, ::MOI.ListOfConstraintIndices{MOI.VectorOfVariables, S}
) where {S <: Union{<:MOI.SOS1, <:MOI.SOS2}}
    indices = MOI.ConstraintIndex{MOI.VectorOfVariables, S}[]
    for (key, info) in model.sos_constraint_info
        if typeof(info.set) == S
            push!(indices, MOI.ConstraintIndex{MOI.VectorOfVariables, S}(key))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    indices = MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}[
        MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}(key)
        for (key, info) in model.quadratic_constraint_info
            if typeof(info.set) == MOI.SecondOrderCone
    ]
    return sort!(indices, by = x -> x.value)
end

function MOI.get(model::Optimizer, ::MOI.ListOfConstraints)
    constraints = Set{Tuple{DataType, DataType}}()
    for info in values(model.variable_info)
        if info.bound == NONE
        elseif info.bound == LESS_THAN
            push!(constraints, (MOI.SingleVariable, MOI.LessThan{Float64}))
        elseif info.bound == GREATER_THAN
            push!(constraints, (MOI.SingleVariable, MOI.GreaterThan{Float64}))
        elseif info.bound == LESS_AND_GREATER_THAN
            push!(constraints, (MOI.SingleVariable, MOI.LessThan{Float64}))
            push!(constraints, (MOI.SingleVariable, MOI.GreaterThan{Float64}))
        elseif info.bound == EQUAL_TO
            push!(constraints, (MOI.SingleVariable, MOI.EqualTo{Float64}))
        elseif info.bound == INTERVAL
            push!(constraints, (MOI.SingleVariable, MOI.Interval{Float64}))
        end
        if info.type == CONTINUOUS
        elseif info.type == BINARY
            push!(constraints, (MOI.SingleVariable, MOI.ZeroOne))
        elseif info.type == INTEGER
            push!(constraints, (MOI.SingleVariable, MOI.Integer))
        elseif info.type == SEMICONTINUOUS
            push!(constraints, (MOI.SingleVariable, MOI.Semicontinuous{Float64}))
        elseif info.type == SEMIINTEGER
            push!(constraints, (MOI.SingleVariable, MOI.Semiinteger{Float64}))
        end
    end
    for info in values(model.affine_constraint_info)
        push!(constraints, (MOI.ScalarAffineFunction{Float64}, typeof(info.set)))
    end
    for info in values(model.quadratic_constraint_info)
        if typeof(info.set) == MOI.SecondOrderCone
            push!(constraints, (MOI.VectorOfVariables, MOI.SecondOrderCone))
        else
            push!(constraints, (MOI.ScalarQuadraticFunction{Float64}, typeof(info.set)))
        end
    end
    for info in values(model.sos_constraint_info)
        push!(constraints, (MOI.VectorOfVariables, typeof(info.set)))
    end
    return collect(constraints)
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveFunctionType)
    if model.is_feasibility
        return nothing
    elseif model.objective_type == SINGLE_VARIABLE
        return MOI.SingleVariable
    elseif model.objective_type == SCALAR_AFFINE
        return MOI.ScalarAffineFunction{Float64}
    else
        @assert model.objective_type == SCALAR_QUADRATIC
        return MOI.ScalarQuadraticFunction{Float64}
    end
end

function MOI.modify(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any},
    chg::MOI.ScalarCoefficientChange{Float64}
)
    chg_coeffs!(
        model.inner, _info(model, c).row, _info(model, chg.variable).column,
        chg.new_coefficient
    )
    _require_update(model)
end

function MOI.modify(
    model::Optimizer,
    c::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}},
    chg::MOI.ScalarCoefficientChange{Float64}
)
    set_dblattrelement!(
        model.inner, "Obj", _info(model, chg.variable).column,
        chg.new_coefficient
    )
    _require_update(model)
end

"""
    _replace_with_matching_sparsity!(
        model::Optimizer,
        previous::MOI.ScalarAffineFunction,
        replacement::MOI.ScalarAffineFunction, row::Int
    )

Internal function, not intended for external use.

Change the linear constraint function at index `row` in `model` from
`previous` to `replacement`. This function assumes that `previous` and
`replacement` have exactly the same sparsity pattern w.r.t. which variables
they include and that both constraint functions are in canonical form (as
returned by `MOIU.canonical()`. Neither assumption is checked within the body
of this function.
"""
function _replace_with_matching_sparsity!(
    model::Optimizer,
    previous::MOI.ScalarAffineFunction,
    replacement::MOI.ScalarAffineFunction, row::Int
)
    rows = fill(Cint(row), length(replacement.terms))
    cols = [Cint(_info(model, t.variable_index).column) for t in replacement.terms]
    coefs = MOI.coefficient.(replacement.terms)
    chg_coeffs!(model.inner, rows, cols, coefs)
    return
end

"""
    _replace_with_different_sparsity!(
        model::Optimizer,
        previous::MOI.ScalarAffineFunction,
        replacement::MOI.ScalarAffineFunction, row::Int
    )

Internal function, not intended for external use.

    Change the linear constraint function at index `row` in `model` from
`previous` to `replacement`. This function assumes that `previous` and
`replacement` may have different sparsity patterns.

This function (and `_replace_with_matching_sparsity!` above) are necessary
because in order to fully replace a linear constraint, we have to zero out the
current matrix coefficients and then set the new matrix coefficients. When the
sparsity patterns match, the zeroing-out step can be skipped.
"""
function _replace_with_different_sparsity!(
    model::Optimizer,
    previous::MOI.ScalarAffineFunction,
    replacement::MOI.ScalarAffineFunction, row::Int
)
    # First, zero out the old constraint function terms.
    rows = fill(Cint(row), length(previous.terms))
    cols = [Cint(_info(model, t.variable_index).column) for t in previous.terms]
    coefs = fill(0.0, length(previous.terms))
    chg_coeffs!(model.inner, rows, cols, coefs)
    # Next, set the new constraint function terms.
    rows = fill(Cint(row), length(replacement.terms))
    cols = [Cint(_info(model, t.variable_index).column) for t in replacement.terms]
    coefs = MOI.coefficient.(replacement.terms)
    chg_coeffs!(model.inner, rows, cols, coefs)
    return
end

"""
    _matching_sparsity_pattern(
        f1::MOI.ScalarAffineFunction{Float64},
        f2::MOI.ScalarAffineFunction{Float64}
    )

Internal function, not intended for external use.

Determines whether functions `f1` and `f2` have the same sparsity pattern
w.r.t. their constraint columns. Assumes both functions are already in
canonical form.
"""
function _matching_sparsity_pattern(
    f1::MOI.ScalarAffineFunction{Float64}, f2::MOI.ScalarAffineFunction{Float64}
)
    if axes(f1.terms) != axes(f2.terms)
        return false
    end
    for (f1_term, f2_term) in zip(f1.terms, f2.terms)
        if MOI.term_indices(f1_term) != MOI.term_indices(f2_term)
            return false
        end
    end
    return true
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:SCALAR_SETS},
    f::MOI.ScalarAffineFunction{Float64}
)
    previous = MOI.get(model, MOI.ConstraintFunction(), c)
    MOI.Utilities.canonicalize!(previous)
    replacement = MOI.Utilities.canonical(f)
    _update_if_necessary(model)
    # If the previous and replacement constraint functions have exactly
    # the same sparsity pattern, then we can take a faster path by just
    # passing the replacement terms to the model. But if their sparsity
    # patterns differ, then we need to first zero out the previous terms
    # and then set the replacement terms.
    row = _info(model, c).row
    if _matching_sparsity_pattern(previous, replacement)
        _replace_with_matching_sparsity!(model, previous, replacement, row)
    else
        _replace_with_different_sparsity!(model, previous, replacement, row)
    end
    current_rhs = get_dblattrelement(model.inner, "RHS", row)
    new_rhs = current_rhs - (replacement.constant - previous.constant)
    set_dblattrelement!(model.inner, "RHS", row, new_rhs)
    _require_update(model)
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintBasisStatus,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S <: SCALAR_SETS}
    row = _info(model, c).row
    _update_if_necessary(model)
    cbasis = get_intattrelement(model.inner, "CBasis", row)
    if cbasis == 0
        return MOI.BASIC
    elseif cbasis == -1
        return MOI.NONBASIC
    else
        error("CBasis value of $(cbasis) isn't defined.")
    end
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintBasisStatus,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}
) where {S <: SCALAR_SETS}
    column = _info(model, c).column
    _update_if_necessary(model)
    vbasis = get_intattrelement(model.inner, "VBasis", column)
    if vbasis == 0
        return MOI.BASIC
    elseif vbasis == -1
        if S <: MOI.LessThan
            return MOI.BASIC
        elseif !(S <: MOI.Interval)
            return MOI.NONBASIC
        else
            return MOI.NONBASIC_AT_LOWER
        end
    elseif vbasis == -2
        MOI.NONBASIC_AT_UPPER
        if S <: MOI.GreaterThan
            return MOI.BASIC
        elseif !(S <: MOI.Interval)
            return MOI.NONBASIC
        else
            return MOI.NONBASIC_AT_UPPER
        end
    elseif vbasis == -3
        return MOI.SUPER_BASIC
    else
        error("VBasis value of $(vbasis) isn't defined.")
    end
end

"""
    compute_conflict(model::Optimizer)

Compute a minimal subset of the constraints and variables that keep the model
infeasible.

See also `Gurobi.ConflictStatus` and `Gurobi.ConstraintConflictStatus`.

Note that if `model` is modified after a call to `compute_conflict`, the
conflict is not purged, and any calls to the above attributes will return values
for the original conflict without a warning.
"""
function compute_conflict(model::Optimizer)
    computeIIS(model.inner)
    return
end

function _ensure_conflict_computed(model::Optimizer)
    if model.inner.conflict == -1
        error("Cannot access conflict status. Call `Gurobi.compute_conflict(model)` first. " *
              "In case the model is modified, the computed conflict will not be purged.")
    end
end

function _is_feasible(model::Optimizer)
    return model.inner.conflict == Gurobi.GRB_INFEASIBLE
end

"""
    ConflictStatus()

Return an `MOI.TerminationStatusCode` indicating the status of the last
computed conflict. If a minimal conflict is found, it will return
`MOI.OPTIMAL`. If the problem is feasible, it will return `MOI.INFEASIBLE`. If
`compute_conflict` has not been called yet, it will return
`MOI.OPTIMIZE_NOT_CALLED`.
"""
struct ConflictStatus <: MOI.AbstractModelAttribute end

MOI.is_set_by_optimize(::ConflictStatus) = true

function MOI.get(model::Optimizer, ::ConflictStatus)
    if model.inner.conflict == -1
        return MOI.OPTIMIZE_NOT_CALLED
    elseif model.inner.conflict == 0
        return MOI.OPTIMAL
    elseif model.inner.conflict == Gurobi.GRB_LOADED
        return MOI.OTHER_ERROR
    elseif model.inner.conflict == Gurobi.GRB_OPTIMAL
        return MOI.OPTIMAL
    elseif model.inner.conflict == Gurobi.GRB_INFEASIBLE
        return MOI.INFEASIBLE
    elseif model.inner.conflict == Gurobi.GRB_INF_OR_UNBD
        return MOI.INFEASIBLE_OR_UNBOUNDED
    elseif model.inner.conflict == Gurobi.GRB_USER_OBJ_LIMIT
        return MOI.OBJECTIVE_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_ITERATION_LIMIT
        return MOI.ITERATION_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_NODE_LIMIT
        return MOI.NODE_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_TIME_LIMIT
        return MOI.TIME_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_SOLUTION_LIMIT
        return MOI.SOLUTION_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_INTERRUPTED
        return MOI.INTERRUPTED
    elseif model.inner.conflict == Gurobi.GRB_NUMERIC
        return MOI.NUMERICAL_ERROR
    elseif model.inner.conflict == Gurobi.GRB_SUBOPTIMAL
        return MOI.OTHER_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_INPROGRESS
        return MOI.OTHER_ERROR
    else
        return MOI.OTHER_ERROR
    end
end

"""
    ConstraintConflictStatus()

A Boolean constraint attribute indicating whether the constraint participates
in the last computed conflict.
"""
struct ConstraintConflictStatus <: MOI.AbstractConstraintAttribute end

MOI.is_set_by_optimize(::ConstraintConflictStatus) = true

function MOI.get(
    model::Optimizer, ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{MOI.SingleVariable, <:MOI.LessThan}
)
    _ensure_conflict_computed(model)
    if _is_feasible(model)
        return false
    end
    return get_intattrelement(model.inner, "IISUB", _info(model, index).column) > 0
end

function MOI.get(
    model::Optimizer, ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{MOI.SingleVariable, <:MOI.GreaterThan}
)
    _ensure_conflict_computed(model)
    if _is_feasible(model)
        return false
    end
    return get_intattrelement(model.inner, "IISLB", _info(model, index).column) > 0
end

function MOI.get(
    model::Optimizer, ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{
        MOI.SingleVariable, <:Union{MOI.EqualTo, MOI.Interval}
    }
)
    _ensure_conflict_computed(model)
    if _is_feasible(model)
        return false
    end
    if get_intattrelement(model.inner, "IISLB", _info(model, index).column) > 0
        return true
    end
    return get_intattrelement(model.inner, "IISUB", _info(model, index).column) > 0
end

function MOI.get(
    model::Optimizer, ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{
        MOI.ScalarAffineFunction{Float64},
        <:Union{MOI.LessThan, MOI.GreaterThan, MOI.EqualTo}
    }
)
    _ensure_conflict_computed(model)
    if _is_feasible(model)
        return false
    end
    return get_intattrelement(model.inner, "IISConstr", _info(model, index).row) > 0
end

function MOI.get(
    model::Optimizer, ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{
        MOI.ScalarQuadraticFunction{Float64},
        <:Union{MOI.LessThan, MOI.GreaterThan}
    }
)
    _ensure_conflict_computed(model)
    if _is_feasible(model)
        return false
    end
    return get_intattrelement(model.inner, "IISQConstr", _info(model, index).row) > 0
end

###
### Constraint attributes
###

# Gurobi constraint attributes as documented at:
# https://www.gurobi.com/documentation/8.1/refman/linear_constraint_attribut.html
# The keys in CONSTR_ATTR_TYPE are listed in the order that they appear in the
# documentation.

# TODO(odow): abstract types are used for the values in the dictionary so that
# we can check if the user passes in an appropriate type for the attribute.
# This could be improved.

const CONSTR_ATTR_TYPE = Dict(
    "Sense" => Char,
    "RHS" => Real,
    "ConstrName" => String,
    "Pi" => Real,
    "Slack" => Real,
    "CBasis" => Integer,
    "DStart" => Real,
    "Lazy" => Integer,
    "IISConstr" => Integer,
    "SARHSLow" => Real,
    "SARHSUp" => Real,
    "FarkasDual" => Real
)

const GETTER_FOR_ELEM_ATTR_TYPE = Dict(
    Integer => Gurobi.get_intattrelement,
    Real => Gurobi.get_dblattrelement,
    Char => Gurobi.get_charattrelement,
    String => Gurobi.get_strattrelement
)

const SETTER_FOR_ELEM_ATTR_TYPE = Dict(
    Integer => Gurobi.set_intattrelement!,
    Real => Gurobi.set_dblattrelement!,
    Char => Gurobi.set_charattrelement!,
    String => Gurobi.set_strattrelement!
)

struct ConstraintAttribute <: MOI.AbstractConstraintAttribute
    name::String
end

function MOI.supports(
    ::Optimizer, attr::ConstraintAttribute, ::Type{<:MOI.ConstraintIndex}
)
    return attr.name ∈ keys(CONSTR_ATTR_TYPE)
end

"""
    MOI.set(model::Optimizer, attr::ConstraintAttribute,
            ci::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any},
            value::T) where T

Set a constraint attribute.

Checks that the attribute exists and that value is correctly typed, but lets
Gurobi handle cases where an attribute's value cannot be set.

Caveat: might fail due to incorrect type for an attribute that cannot be set
anyway.
"""
function MOI.set(
    model::Optimizer, attr::ConstraintAttribute,
    ci::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}},
    value::T
) where T
    MOI.supports(model, attr, typeof(ci)) ||
        throw(MOI.UnsupportedAttribute(attr))
    if !(T <: CONSTR_ATTR_TYPE[attr.name])
        throw(ArgumentError(
            "Attribute $(attr.name) is $(CONSTR_ATTR_TYPE[attr.name]) but $T provided."
        ))
    end
    setter! = SETTER_FOR_ELEM_ATTR_TYPE[CONSTR_ATTR_TYPE[attr.name]]
    setter!(model.inner, attr.name, _info(model, ci).row, value)
    _require_update(model)
    return
end

function MOI.get(
    model::Optimizer, attr::ConstraintAttribute,
    ci::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}}
)
    MOI.supports(model, attr, typeof(ci)) ||
        throw(MOI.UnsupportedAttribute(attr))
    getter = GETTER_FOR_ELEM_ATTR_TYPE[CONSTR_ATTR_TYPE[attr.name]]
    _update_if_necessary(model)
    return getter(model.inner, attr.name, _info(model, ci).row)
end

###
### Variable attributes
###

# Gurobi variable attributes as documented at:
# https://www.gurobi.com/documentation/8.1/refman/variable_attributes.html
# The keys in VAR_ATTR_TYPE are listed in the order in which they appear in the
# documentation.
const VAR_ATTR_TYPE = Dict(
    "LB" => Real,
    "UB" => Real,
    "Obj" => Real,
    "VType" => Char,
    "VarName" => String,
    "X" => Real,
    "Xn" => Real,
    "RC" => Real,
    "BarX" => Real,
    "Start" => Real,
    "VarHintVal" => Real,
    "VarHintPri" => Integer,
    "BranchPriority" => Integer,
    "Partition" => Integer,
    "VBasis" => Integer,
    "PStart" => Real,
    "IISLB" => Integer,
    "IISUB" => Integer,
    "PWLObjCvx" => Integer,
    "SAOBJLow" => Real,
    "SAObjUp" => Real,
    "SALBLow" => Real,
    "SALBUp" => Real,
    "SAUBLow" => Real,
    "SAUBUp" => Real,
    "UnbdRay" => Real,
)

struct VariableAttribute <: MOI.AbstractVariableAttribute
    name::String
end

function MOI.supports(
    ::Optimizer, attr::VariableAttribute, ::Type{<:MOI.VariableIndex}
)
    return attr.name ∈ keys(VAR_ATTR_TYPE)
end

"""
    MOI.set(model::Optimizer, attr::VariableAttribute,
            vi::MOI.VariableIndex, value::T) where T

Set a variable attribute.

Checks that the attribute exists and that value is correctly typed, but lets
Gurobi handle cases where an attribute's value cannot be set.

Caveat: might fail due to incorrect type for an attribute that cannot be set
anyway.
"""
function MOI.set(
    model::Optimizer, attr::VariableAttribute,
    vi::MOI.VariableIndex, value::T
) where T
    MOI.supports(model, attr, typeof(vi)) ||
        throw(MOI.UnsupportedAttribute(attr))
    if !(T <: VAR_ATTR_TYPE[attr.name])
        throw(ArgumentError(
            "Attribute $(attr.name) is $(VAR_ATTR_TYPE[attr.name]) but $T provided."
        ))
    end
    setter! = SETTER_FOR_ELEM_ATTR_TYPE[VAR_ATTR_TYPE[attr.name]]
    setter!(model.inner, attr.name, _info(model, vi).column, value)
    _require_update(model)
    return
end

function MOI.get(
    model::Optimizer, attr::VariableAttribute, vi::MOI.VariableIndex
)
    MOI.supports(model, attr, typeof(vi)) ||
        throw(MOI.UnsupportedAttribute(attr))
    getter = GETTER_FOR_ELEM_ATTR_TYPE[VAR_ATTR_TYPE[attr.name]]
    _update_if_necessary(model)
    return getter(model.inner, attr.name, _info(model, vi).column)
end

###
### Model attributes
###

# Gurobi model attributes as documented at:
# https://www.gurobi.com/documentation/8.1/refman/model_attributes.html
# The keys in MODEL_ATTR_TYPE are listed in the order in which they appear in
# the documentation.
const MODEL_ATTR_TYPE = Dict(
    "NumConstrs" => Integer,
    "NumVars" => Integer,
    "NumSOS" => Integer,
    "NumQConstrs" => Integer,
    "NumGenConstrs" => Integer,
    "NumNZs" => Integer,
    "DNumNZs" => Real,
    "NumQNZs" => Integer,
    "NumQCNZs" => Integer,
    "NumIntVars" => Integer,
    "NumBinVars" => Integer,
    "NumPWLObjVars" => Integer,
    "ModelName" => String,
    "ModelSense" => Integer,
    "ObjCon" => Real,
    "ObjVal" => Real,
    "ObjBound" => Real,
    "ObjBoundC" => Real,
    "PoolObjBound" => Real,
    "PoolObjVal" => Real,
    "MIPGap" => Real,
    "Runtime" => Real,
    "Status" => Integer,
    "SolCount" => Integer,
    "IterCount" => Real,
    "BarIterCount" => Integer,
    "NodeCount" => Real,
    "IsMIP" => Integer,
    "IsQP" => Integer,
    "IsQCP" => Integer,
    "IsMultiObj" => Integer,
    "IISMinimal" => Integer,
    "MaxCoeff" => Real,
    "MinCoeff" => Real,
    "MaxBound" => Real,
    "MinBound" => Real,
    "MaxObjCoeff" => Real,
    "MinObjCoeff" => Real,
    "MaxRHS" => Real,
    "MinRHS" => Real,
    "MaxQCCoeff" => Real,
    "MinQCCoeff" => Real,
    "MaxQCLCoeff" => Real,
    "MinQCLCoeff" => Real,
    "MaxQCRHS" => Real,
    "MinQCRHS" => Real,
    "MaxQObjCoeff" => Real,
    "MinQObjCoeff" => Real,
    "Kappa" => Real,
    "KappaExact" => Real,
    "FarkasProof" => Real,
    "TuneResultCount" => Integer,
    "NumStart" => Integer,
    "LicenseExpiration" => Integer,
    "JobID" => String,
    "Server" => String,
)

const GETTER_FOR_MODEL_ATTR_TYPE = Dict(
    Integer => Gurobi.get_intattr,
    Real => Gurobi.get_dblattr,
    String => Gurobi.get_strattr,
)

const SETTER_FOR_MODEL_ATTR_TYPE = Dict(
    Integer => Gurobi.set_intattr!,
    Real => Gurobi.set_dblattr!,
    String => Gurobi.set_strattr!
)

struct ModelAttribute <: MOI.AbstractModelAttribute
    name::String
end

function MOI.supports(::Optimizer, attr::ModelAttribute)
    return attr.name ∈ keys(MODEL_ATTR_TYPE)
end

"""
    MOI.set(model::Optimizer, attr::ModelAttribute, value::T) where T

Set a model attribute.

Checks that the attribute exists and that value is correctly typed, but lets
Gurobi handle cases where an attribute's value cannot be set.

Caveat: might fail due to incorrect type for an attribute that cannot be set
anyway.
"""
function MOI.set(model::Optimizer, attr::ModelAttribute, value::T) where T
    MOI.supports(model, attr) || throw(MOI.UnsupportedAttribute(attr))
    if !(T <: MODEL_ATTR_TYPE[attr.name])
        throw(ArgumentError(
            "Attribute $(attr.name) is $(MODEL_ATTR_TYPE[attr.name]) but $T provided."
        ))
    end
    setter! = SETTER_FOR_MODEL_ATTR_TYPE[MODEL_ATTR_TYPE[attr.name]]
    setter!(model.inner, attr.name, value)
    _require_update(model)
    return
end

function MOI.get(model::Optimizer, attr::ModelAttribute)
    MOI.supports(model, attr) || throw(MOI.UnsupportedAttribute(attr))
    getter = GETTER_FOR_MODEL_ATTR_TYPE[MODEL_ATTR_TYPE[attr.name]]
    _update_if_necessary(model)
    return getter(model.inner, attr.name)
end

###
### VectorOfVariables-in-SecondOrderCone
###

function _info(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    if haskey(model.quadratic_constraint_info, c.value)
        return model.quadratic_constraint_info[c.value]
    end
    throw(MOI.InvalidIndex(c))
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.VectorOfVariables, s::MOI.SecondOrderCone
)
    if length(f.variables) != s.dimension
        error("Dimension of $(s) does not match number of terms in $(f)")
    end

    # SOC is the cone: t ≥ ||x||₂ ≥ 0. In quadratic form, this is
    # t² - Σᵢ xᵢ² ≥ 0 and t ≥ 0.

    # First, check the lower bound on t.

    _update_if_necessary(model)
    t_info = _info(model, f.variables[1])
    lb = _get_variable_lower_bound(model, t_info)
    if isnan(t_info.lower_bound_if_soc) && lb < 0.0
        # If `t_info.lower_bound_if_bounded` is active, this just makes
        # `t_info.lower_bound_if_soc` equal to it. If `lower_bound_if_bounded`
        # is set after, then it will call `_set_variable_lower_bound` and
        # update `lower_bound_if_soc` accordingly.
        t_info.lower_bound_if_soc = lb
        set_dblattrelement!(model.inner, "LB", t_info.column, 0.0)
    end
    t_info.num_soc_constraints += 1

    # Now add the quadratic constraint.

    I = Cint[_info(model, v).column for v in f.variables]
    V = fill(Cdouble(-1.0), length(f.variables))
    V[1] = 1.0
    add_qconstr!(model.inner, Cint[], Cdouble[], I, I, V, Cchar('>'), 0.0)
    _require_update(model)
    model.last_constraint_index += 1
    model.quadratic_constraint_info[model.last_constraint_index] =
        ConstraintInfo(length(model.quadratic_constraint_info) + 1, s)
    return MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}(model.last_constraint_index)
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    info = get(model.quadratic_constraint_info, c.value, nothing)
    return info !== nothing && typeof(info.set) == MOI.SecondOrderCone
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    _update_if_necessary(model)
    f = MOI.get(model, MOI.ConstraintFunction(), c)
    info = _info(model, c)
    delqconstrs!(model.inner, [info.row])
    _require_update(model)
    for (key, info_2) in model.quadratic_constraint_info
        if info_2.row > info.row
            info_2.row -= 1
        end
    end
    model.name_to_constraint_index = nothing
    delete!(model.quadratic_constraint_info, c.value)
    # Reset the lower bound on the `t` variable.
    t_info = _info(model, f.variables[1])
    t_info.num_soc_constraints -= 1
    if t_info.num_soc_constraints > 0
        # Don't do anything. There are still SOC associated with this variable.
        return
    elseif isnan(t_info.lower_bound_if_soc)
        # Don't do anything. It must have a >0 lower bound anyway.
        return
    end
    # There was a previous bound that we over-wrote, and it must have been
    # < 0 otherwise we wouldn't have needed to overwrite it.
    @assert t_info.lower_bound_if_soc < 0.0
    # Also, if there is a cached value in `t_info.lower_bound_if_bounded`
    # (i.e., `t_info.bound` is not `NONE` nor `LESS_THAN`), then it has
    # followed any changes `t_info.lower_bound_if_soc` has gone through
    # and has the same value. So when LB is set to the old value of
    # `lower_bound_if_soc` below, then `lower_bound_if_bounded` will stay
    # correct.
    @assert isnan(t_info.lower_bound_if_bounded) ||
        t_info.lower_bound_if_bounded == t_info.lower_bound_if_soc
    tmp_lower_bound = t_info.lower_bound_if_soc
    t_info.lower_bound_if_soc = NaN
    set_dblattrelement!(model.inner, "LB", t_info.column, tmp_lower_bound)
    _require_update(model)
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    return _info(model, c).set
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    _update_if_necessary(model)
    a, b, I, J, V = getqconstr(model.inner, _info(model, c).row)
    @assert length(a) == length(b) == 0  # Check for no linear terms.
    t = nothing
    x = MOI.VariableIndex[]
    for (i, j, coef) in zip(I, J, V)
        v = model.variable_info[CleverDicts.LinearIndex(i + 1)].index
        @assert i == j  # Check for no off-diagonals.
        if coef == 1.0
            @assert t === nothing  # There should only be one `t`.
            t = v
        else
            @assert coef == -1.0  # The coefficients _must_ be -1 for `x` terms.
            push!(x, v)
        end
    end
    @assert t !== nothing  # Check that we found a `t` variable.
    return MOI.VectorOfVariables([t; x])
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    f = MOI.get(model, MOI.ConstraintFunction(), c)
    return MOI.get(model, MOI.VariablePrimal(), f.variables)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone},
    name::String
)
    info = _info(model, c)
    if !isempty(info.name) && model.name_to_constraint_index !== nothing
        delete!(model.name_to_constraint_index, info.name)
    end
    _update_if_necessary(model)
    set_strattrelement!(model.inner, "QCName", info.row, name)
    _require_update(model)
    info.name = name
    if model.name_to_constraint_index === nothing || isempty(name)
        return
    end
    if haskey(model.name_to_constraint_index, name)
        model.name_to_constraint_index = nothing
    else
        model.name_to_constraint_index[c] = name
    end
    return
end
