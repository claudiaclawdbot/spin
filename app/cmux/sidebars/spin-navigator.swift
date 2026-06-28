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
        Text("S").foregroundColor("#FF7ADF")
        Text("P").foregroundColor("#00E5FF")
        Text("I").foregroundColor("#39FF14")
        Text("N").foregroundColor("#EAB308")
        Text("!").foregroundColor("#A855F7")
    }
    .font(.system(size: 22, design: .rounded))
    .fontWeight(.heavy)
    .lineLimit(1)
}

func coordinatorButton(_ w) -> some View {
    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
        HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .foregroundColor(w.selected ? "#7EEBFF" : "#FF7ADF")
                .frame(width: 4, height: 42)
            VStack(alignment: .leading, spacing: 2) {
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
                .foregroundColor(w.selected ? "#7EEBFF" : "#00E5FF")
                .font(.system(size: 14))
        }
        .padding(6)
        .background { RoundedRectangle(cornerRadius: 8).foregroundColor(w.selected ? "#2A1830" : "#1A1018").opacity(w.selected ? 0.74 : 0.50) }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(w.selected ? "#7EEBFF" : "#FF7ADF", lineWidth: 1)
                .opacity(w.selected ? 0.82 : 0.34)
        }
    }
    .help("Open the SPIN Navigator floor")
}

func onboardingButton(_ w) -> some View {
    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundColor("#EAB308")
                .font(.system(size: 11))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
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
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background { RoundedRectangle(cornerRadius: 6).foregroundColor(w.selected ? "#3A2A00" : "#171009").opacity(w.selected ? 0.70 : 0.42) }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(w.selected ? "#EAB308" : "#FF7ADF", lineWidth: 0.75)
                .opacity(w.selected ? 0.68 : 0.20)
        }
    }
}

func projectRow(_ w) -> some View {
    HStack(spacing: 5) {
        Circle()
            .foregroundColor(w.selected ? "#00E5FF" : (w.unread > 0 ? "#EAB308" : "#8A7280"))
            .frame(width: 4, height: 4)
        Text(w.title)
            .font(.system(size: 11))
            .fontWeight(w.selected ? .semibold : .regular)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .truncationMode(.tail)
            .frame(width: 82, alignment: .leading)
            .layoutPriority(2)
        Spacer(minLength: 0)
        if w.unread > 0 {
            Text("\(w.unread)")
                .font(.system(size: 7, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor("#101014")
                .padding(2)
                .background { Circle().foregroundColor("#EAB308") }
                .padding(.trailing, 14)
        } else {
            Spacer()
                .frame(width: 14)
        }
    }
    .padding(.leading, 6)
    .padding(.trailing, 2)
    .padding(.vertical, 0)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 24)
    .background { RoundedRectangle(cornerRadius: 6).foregroundColor(w.selected ? "#2A1830" : "#1B1118").opacity(w.selected ? 0.66 : 0.40) }
    .overlay {
        RoundedRectangle(cornerRadius: 6)
            .stroke(w.selected ? "#7EEBFF" : "#FF7ADF", lineWidth: 0.6)
            .opacity(w.selected ? 0.72 : 0.24)
    }
    .onTapGesture { cmux("workspace.select", workspace_id: w.id) }
    .help("Open this project floor")
    .overlay(alignment: .trailing) {
        Button(action: { cmux("workspace.close", workspace_id: w.id) }) {
            Image(systemName: "xmark")
                .font(.system(size: 7))
                .fontWeight(.semibold)
                .foregroundColor(w.selected ? "#FFFFFF" : "#FFD1F5")
                .frame(width: 12, height: 12)
                .background { Circle().foregroundColor(w.selected ? "#FF7ADF" : "#2B1325").opacity(w.selected ? 0.58 : 0.44) }
                .overlay {
                    Circle()
                        .stroke("#FFB8EA", lineWidth: 0.6)
                        .opacity(w.selected ? 0.54 : 0.28)
                }
        }
        .buttonStyle(.plain)
        .help("Close project tab. This only removes the visible cmux floor; it does not delete project files or the repository.")
        .padding(.trailing, 6)
    }
}

VStack(alignment: .leading, spacing: 4) {
    let coordinators = workspaces.filter { isSpinCoordinator($0) }
    let onboarding = workspaces.filter { isSpinOnboarding($0) }
    let projectFloors = workspaces.filter { isProjectFloor($0) }

    HStack {
        Text("SPIN")
            .font(.system(size: 12))
            .fontWeight(.semibold)
            .foregroundColor("#FF7ADF")
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
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .foregroundColor("#FF7ADF")
                    .frame(width: 4, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    spinWord()
                    Text("Navigator floor offline")
                        .font(.system(size: 10))
                        .foregroundColor("#00E5FF")
                }
                Spacer()
            }
            .padding(6)
            .background { RoundedRectangle(cornerRadius: 8).foregroundColor("#1A1018").opacity(0.50) }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke("#FF7ADF", lineWidth: 1)
                    .opacity(0.34)
            }
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
    .padding(.horizontal, 5)
    .padding(.top, 0)

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
.frame(maxWidth: .infinity, alignment: .leading)
.padding(10)
