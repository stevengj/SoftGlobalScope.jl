VERSION < v"0.7.0-beta2.199" && __precompile__()

"""
SoftGlobalScope is a package that simplifies the [variable scoping rules](https://docs.julialang.org/en/stable/manual/variables-and-scoping/)
for code in *global* scope.   It is intended for interactive shells (the REPL, [IJulia](https://github.com/JuliaLang/IJulia.jl),
etcetera) to make it easier to work interactively with Julia, especially for beginners.

In particular, SoftGlobalScope provides a function `softscope` that can transform Julia code from using the default
"hard" (local) scoping rules to simpler "soft" scoping rules in global scope, and a function `softscope_include_string`
that can evaluate a whole string (similar to `include_string`) using these rules.

For example, if `s` is a global variable in the current module (e.g. `Main`), the following code is an error in
Julia 1.0:
```
for i = 1:10
    s += i     # declares a new local variable `s`
end
```
Instead, you can transform the expression using `softscope` to automatically insert the necessary `global` keyword:
```jl
julia> softscope(Main, :(for i = 1:10
           s += i
       end))
:(for i = 1:10
      #= REPL[3]:2 =#
      global s += i
  end)
```
You can then execute the statement with `eval`. Alternatively, you can decorate
the expression with the `@softscope` macro:
```jl
julia> s = 0;

julia> @softscope for i = 1:10
           s += i
       end

julia> s
55
```
This macro should only be used in the global scope (e.g., via the REPL); using
this macro within a function is likely to lead to unintended consequences.

You can execute an entire sequence of statements using "soft" global scoping
rules via `softscope_include_string`:
```jl
julia> softscope_include_string(Main, \"\"\"
       s = 0
       for i = 1:10
           s += i
       end
       s
       \"\"\")
55
```
(This function works like `include_string`, returning the value of the last evaluated expression.)

On Julia 0.6, `softscope` is the identity and `softscope_include_string` is equivalent to
`include_string`, since the `global` keyword is not needed there.
"""
module SoftGlobalScope
export softscope, softscope_include_string, @softscope

if VERSION < v"0.7.0-DEV.2308" # before julia#19324 we don't need to change the ast
    softscope(m::Module, ast) = ast
    softscope_include_string(m::Module, code::AbstractString, filename::AbstractString="string") =
        @static isdefined(Base, Symbol("@__MODULE__")) ? include_string(m, code, filename) : Core.eval(m, :(include_string($code, $filename)))
else
    using Base.Meta: isexpr

    const assignments = Set((:(=), :(+=), :(-=), :(*=), :(/=), :(//=), :(\=), :(^=), :(÷=), :(%=), :(<<=), :(>>=), :(>>>=), :(|=), :(&=), :(⊻=), :($=)))

    # extract the local variable names (e.g. `[:x]`) from assignments (e.g. `x=1`) etc.
    function localvars(ex::Expr)
        if isexpr(ex, :(=)) || isexpr(ex, :(::))
            return localvars(ex.args[1])
        elseif isexpr(ex, :tuple) || isexpr(ex, :block)
            return localvars(ex.args)
        else
            return Any[]
        end
    end
    localvars(ex::Symbol) = [ex]
    localvars(ex) = Any[]
    localvars(a::Vector) = vcat(localvars.(a)...)

    """
        _softscope(ex, globals, locals, insertglobal::Bool=false)

    Transform expression `ex` to "soft" scoping rules, where `globals` is a collection
    (e.g. `Set`) of global-variable symbols to implicitly qualify with `global`, and
    `insertglobal` is whether to insert the `global` keyword at the top level of
    `ex`.  (Usually, you pass `insertglobal=false` to start with and then it is
    recursively set to `true` for local scopes introduced by `for` etcetera.)
    NOTE: `_softscope`` may mutate the `globals` argument (if there are `local` declarations.)
    """
    function _softscope(ex::Expr, globals, locals, insertglobal::Bool=false)
        if isexpr(ex, :for) || isexpr(ex, :while)
            return Expr(ex.head, ex.args[1], _softscope(ex.args[2], copy(globals), copy(locals), true))
        elseif isexpr(ex, :try)
            try_clause = _softscope(ex.args[1], copy(globals), copy(locals), true)
            catch_clause = _softscope(ex.args[3], copy(globals), ex.args[2] isa Symbol ? union!(locals, ex.args[2:2]) : copy(locals), true)
            finally_clause = _softscope(ex.args[4], copy(globals), copy(locals), true)
            return Expr(:try, try_clause, ex.args[2], catch_clause, finally_clause)
        elseif isexpr(ex, :let)
            letlocals = union(locals, localvars(ex.args[1]))
            return Expr(ex.head, ex.args[1], _softscope(ex.args[2], copy(globals), letlocals, true))
        elseif isexpr(ex, :block) || isexpr(ex, :if)
            return Expr(ex.head, _softscope.(ex.args, Ref(globals), Ref(locals), insertglobal)...)
        elseif isexpr(ex, :global)
            union!(globals, localvars(ex.args))
            return ex
        elseif isexpr(ex, :local)
            union!(locals, localvars(ex.args)) # affects globals in surrounding scope!
            return ex
        elseif insertglobal && ex.head in assignments && ex.args[1] in globals && !(ex.args[1] in locals)
            return Expr(:global, Expr(ex.head, ex.args[1], _softscope(ex.args[2], globals, locals, insertglobal)))
        elseif !insertglobal && isexpr(ex, :(=)) # only assignments in the global scope need to be considered
            union!(globals, localvars(ex))
            return ex
        else
            return ex
        end
    end
    _softscope(ex, globals, locals, insertglobal::Bool=false) = ex

    softscope(m::Module, ast) = _softscope(ast, Set(@static VERSION < v"0.7.0-DEV.3526" ? names(m, true) : names(m, all=true)), Set{Symbol}())

    function softscope_include_string(m::Module, code::AbstractString, filename::AbstractString="string")
        # use the undocumented parse_input_line function so that we preserve
        # the filename and line-number information.
        expr = Base.parse_input_line("begin; "*code*"\nend\n", filename=filename)
        # expr.args should consist of LineNumberNodes followed by expressions to evaluate
        return Core.eval(m, softscope(m, expr))
    end
end

"""
    softscope(m::Module, ast)

Transform the abstract syntax tree `ast` (a quoted Julia expression) to use "soft"
scoping rules for the global variables defined in `m`, returning the new expression.
"""
softscope

if VERSION < v"0.7.0-DEV.481" # the version that __module__ was introduced
    macro softscope(ast)
        esc(softscope(current_module(), ast))
    end
else
    macro softscope(ast)
        esc(softscope(__module__, ast))
    end
end

"""
    @softscope(expr)

Apply "soft" scoping rules to the argument of the macro. For example
```jl
julia> s = 0;

julia> @softscope for i = 1:10
           s += i
       end

julia> s
55
```
"""
:(@softscope)

"""
    softscope_include_string(m::Module, code::AbstractString, filename::AbstractString="string")

Like [`include_string`](@ref), but evaluates `code` using "soft"
scoping rules for the global variables defined in `m`.
"""
softscope_include_string

end # module
