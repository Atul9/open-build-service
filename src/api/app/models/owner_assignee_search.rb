class OwnerAssigneeSearch < OwnerSearch
  def for(search_string)
    @match_all = limit.zero?
    @deepest = (limit < 0)

    @instances_without_definition = []
    @maintainers = []

    # search in each marked project
    object_projects(search_string).each do |project|
      @rolefilter = filter(project)
      @already_checked = {}
      @rootproject = project
      @lookup_limit = limit.to_i
      @devel_disabled = devel_disabled?(project)
      find_assignees search_string
      webui_mode = params[:webui_mode].present?
      return @instances_without_definition if webui_mode && @maintainers.empty?
    end
    @maintainers
  end

  protected

  def create_owner(pkg)
    Owner.new(rootproject: @rootproject.name, filter: @rolefilter, project: pkg.project.name, package: pkg.name)
  end

  def extract_maintainer(pkg, objfilter = nil)
    return unless pkg && Package.check_access?(pkg)

    m = create_owner(pkg)
    # no filter defined, so do not check for roles and just return container
    return m if @rolefilter.empty?
    # lookup in package container
    extract_from_container(m, pkg, @rolefilter, objfilter)

    # did it it match? if not fallback to project level
    unless m.users || m.groups
      m.package = nil
      extract_from_container(m, pkg.project, @rolefilter, objfilter)
    end
    # still not matched? Ignore it
    return unless m.users || m.groups

    m
  end

  def extract_owner(pkg, owner)
    # optional check for devel package instance first
    if @devel_disabled
      m = nil
    else
      m = extract_maintainer(pkg.resolve_devel_package, owner)
    end
    m || extract_maintainer(pkg, owner)
  end

  def lookup_package_owner(pkg, owner)
    return nil if @already_checked[pkg.id]

    @already_checked[pkg.id] = 1
    @lookup_limit -= 1

    m = extract_owner(pkg, owner)
    # found entry
    return m if m

    # no match, loop about projects below with this package container name
    pkg.project.expand_all_projects(allow_remote_projects: false).each do |prj|
      p = prj.packages.find_by_name(pkg.name)
      next if p.nil? || @already_checked[p.id]

      @already_checked[p.id] = 1

      m = extract_owner(p, owner)
      break if m && !@deepest
    end

    # found entry
    m
  end

  def parse_binary_info(b, prj)
    return unless b['project'] == prj.name

    package_name = b['package']
    package_name.gsub!(/\.[^\.]*$/, '') if prj.is_maintenance_release?
    pkg = prj.packages.find_by_name(package_name)
    return if pkg.nil? || pkg.is_patchinfo?

    # the "" means any matching relationships will get taken
    m = lookup_package_owner(pkg, '')
    unless m
      # collect all no matched entries
      @instances_without_definition << create_owner(pkg)
      return
    end

    # remember as deepest candidate
    if @deepest
      @deepest_match = m
      return
    end

    # add matching entry
    @maintainers << m
    @lookup_limit -= 1
    true
  end

  def find_assignees(binary_name)
    projects = @rootproject.expand_all_projects(allow_remote_projects: false)

    # binary search via all projects
    data = Xmlhash.parse(Backend::Api::Search.binary(projects.map(&:name), binary_name))
    # found binary package?
    return [] if data['matches'].to_i.zero?

    @deepest_match = nil
    projects.each do |prj| # project link order
      data.elements('binary').each do |b| # no order
        next unless parse_binary_info(b, prj)
        return @maintainers if @lookup_limit < 1 && !@match_all
      end
    end

    @maintainers << @deepest_match if @deepest_match
  end
end
