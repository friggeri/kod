import FontCore
import ThemeCore
import WorkspaceCore
@testable import EditorUI
@testable import KodUIComponents

extension EditorGroupViewController {
    convenience init(groupID: EditorGroupID, state: EditorGroupState) {
        self.init(
            groupID: groupID,
            state: state,
            appearanceCenter: AppearanceCenter(
                testing: AppearanceCenter.Snapshot(
                    theme: BundledThemes.dark,
                    fontSettings: .default
                )
            )
        )
    }
}
