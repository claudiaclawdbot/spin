func isSpinCoordinator(_ w) -> Bool {
    return w.title == "SPIN Coordinator"
}

func isSpinOnboarding(_ w) -> Bool {
    return w.title == "SPIN Onboarding"
}

func isProjectFloor(_ w) -> Bool {
    return !isSpinCoordinator(w) && !isSpinOnboarding(w)
}

func workspaceSubtitle(_ w) -> String {
    if w.description != nil && w.description != "" { return w.description }
    if w.latestPrompt != nil && w.latestPrompt != "" { return w.latestPrompt }
    if w.branch != nil && w.branch != "" { return w.branch }
    if w.portCount > 0 { return "\(w.portCount) ports" }
    return "\(w.tabCount) tabs"
}

func spinWord() -> some View {
    HStack(spacing: 1) {
        Text("S").foregroundColor("#FF2BD6")
        Text("P").foregroundColor("#00E5FF")
        Text("I").foregroundColor("#39FF14")
        Text("N").foregroundColor("#EAB308")
        Text("!").foregroundColor("#A855F7")
    }
    .font(.system(size: 26, design: .rounded))
    .fontWeight(.heavy)
    .lineLimit(1)
}

func coordinatorButton(_ w) -> some View {
    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
        HStack(alignment: .center, spacing: 9) {
            RoundedRectangle(cornerRadius: 3)
                .foregroundColor(w.selected ? "#39FF14" : "#FF2BD6")
                .frame(width: 5, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                spinWord()
                HStack(spacing: 5) {
                    Label("Navigator", systemImage: "circle.hexagongrid.fill")
                        .font(.system(size: 10))
                        .foregroundColor("#00E5FF")
                    if w.unread > 0 {
                        Text("\(w.unread)")
                            .font(.system(size: 9, design: .monospaced))
                            .fontWeight(.semibold)
                            .foregroundColor("#101014")
                            .padding(4)
                            .background { Capsule().foregroundColor("#EAB308") }
                    }
                }
            }
            Spacer()
            Image(systemName: "arrow.up.forward.circle.fill")
                .foregroundColor(w.selected ? "#39FF14" : "#00E5FF")
                .imageScale(.large)
        }
        .padding(8)
        .background { RoundedRectangle(cornerRadius: 8).foregroundColor(w.selected ? "#260033" : "#140014").opacity(w.selected ? 1.0 : 0.92) }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(w.selected ? "#39FF14" : "#6A0053", lineWidth: 1)
        }
    }
    .help("Open the SPIN Navigator floor")
}

func onboardingButton(_ w) -> some View {
    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundColor("#EAB308")
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Onboarding")
                    .font(.system(size: 12))
                    .fontWeight(w.selected ? .semibold : .regular)
                    .lineLimit(1)
                Text(workspaceSubtitle(w))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .padding(6)
        .background { RoundedRectangle(cornerRadius: 7).foregroundColor(w.selected ? "#3A2A00" : "#160F00").opacity(w.selected ? 1.0 : 0.72) }
    }
}

func projectRow(_ w) -> some View {
    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
        HStack(spacing: 8) {
            Circle()
                .foregroundColor(w.selected ? "#00E5FF" : (w.unread > 0 ? "#EAB308" : "#6F5868"))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.title)
                    .font(.system(size: 12))
                    .fontWeight(w.selected ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(workspaceSubtitle(w))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if w.unread > 0 {
                Text("\(w.unread)")
                    .font(.system(size: 9, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor("#101014")
                    .padding(4)
                    .background { Circle().foregroundColor("#EAB308") }
            }
        }
        .padding(6)
        .background { RoundedRectangle(cornerRadius: 7).foregroundColor(w.selected ? "#053247" : "#210019").opacity(w.selected ? 1.0 : 0.72) }
    }
}

VStack(alignment: .leading, spacing: 8) {
    let coordinators = workspaces.filter { isSpinCoordinator($0) }
    let onboarding = workspaces.filter { isSpinOnboarding($0) }
    let projectFloors = workspaces.filter { isProjectFloor($0) }

    HStack {
        Text("SPIN")
            .font(.system(size: 12))
            .fontWeight(.semibold)
            .foregroundColor("#FF2BD6")
        Spacer()
        Text(clock.time)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
    }

    if coordinators.count > 0 {
        ForEach(coordinators.prefix(1)) { w in
            coordinatorButton(w)
        }
    } else {
        Button(action: { cmux("sidebar.custom.open", name: "spin-navigator") }) {
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 3)
                    .foregroundColor("#FF2BD6")
                    .frame(width: 5, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    spinWord()
                    Text("Navigator floor offline")
                        .font(.system(size: 10))
                        .foregroundColor("#00E5FF")
                }
                Spacer()
            }
            .padding(8)
            .background { RoundedRectangle(cornerRadius: 8).foregroundColor("#140014") }
        }
    }

    if onboarding.count > 0 {
        ForEach(onboarding.prefix(1)) { w in
            onboardingButton(w)
        }
    }

    HStack(spacing: 6) {
        Label("Project floors", systemImage: "rectangle.3.group.fill")
            .font(.system(size: 10))
            .fontWeight(.semibold)
            .foregroundColor("#00E5FF")
        Text("\(projectFloors.count)")
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor("#EAB308")
        Spacer()
    }
    .padding(.horizontal, 6)
    .padding(.top, 2)

    Divider()

    if projectFloors.count == 0 {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.badge.plus")
                .font(.system(size: 18))
                .foregroundColor("#6F5868")
            Text("No project floors")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
    } else {
        ForEach(projectFloors.prefix(40)) { w in
            projectRow(w)
        }
    }

    Divider()

    VStack(alignment: .leading, spacing: 6) {
        Button(action: { cmux("workspace.create", title: "New SPIN Project") }) {
            Label("New Project Floor", systemImage: "plus.circle")
        }
        Button(action: { cmux("sidebar.custom.open", name: "spin-navigator") }) {
            Label("Navigator Panel", systemImage: "sidebar.left")
        }
    }
    .font(.caption)

    Spacer()
}
.padding(10)
