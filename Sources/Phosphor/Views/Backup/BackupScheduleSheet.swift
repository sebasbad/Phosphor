import SwiftUI

/// Sheet for configuring scheduled backups.
struct BackupScheduleSheet: View {

    @StateObject private var scheduler = BackupScheduler()
    @EnvironmentObject private var deviceVM: DeviceViewModel
    @EnvironmentObject private var backupVM: BackupViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Scheduled Backups")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()
            Divider()

            Form {
                Section("Schedule") {
                    ScheduledBackupDevicePicker(
                        targetUDID: Binding(
                            get: { scheduler.schedule.targetUDID },
                            set: { targetUDID in
                                let targetName = deviceVM.devices.first(where: { $0.id == targetUDID })?.name
                                scheduler.selectSchedule(targetUDID: targetUDID, targetName: targetName)
                            }
                        ),
                        targetName: $scheduler.schedule.targetName,
                        devices: deviceVM.devices,
                        wifiOnly: scheduler.schedule.wifiOnly
                    )

                    Toggle("Enable automatic backups", isOn: $scheduler.schedule.enabled)
                        .disabled(
                            !scheduler.schedule.enabled &&
                            scheduler.schedule.targetUDID == nil &&
                            deviceVM.devices.count != 1
                        )

                    if scheduler.schedule.enabled {
                        Picker("Frequency", selection: $scheduler.schedule.frequency) {
                            ForEach(BackupScheduler.Frequency.allCases, id: \.self) { freq in
                                Text(LocalizedStringKey(freq.rawValue)).tag(freq)
                            }
                        }

                        HStack {
                            Text("Preferred time")
                            Spacer()
                            Picker("Hour", selection: $scheduler.schedule.preferredHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d:00", h)).tag(h)
                                }
                            }
                            .frame(width: 100)
                        }

                        Toggle("Wi-Fi only (skip if Wi-Fi is not available)", isOn: $scheduler.schedule.wifiOnly)
                        Toggle("Incremental when possible (faster)", isOn: $scheduler.schedule.incrementalOnly)
                        if scheduler.schedule.incrementalOnly {
                            Text("The first scheduled run will create the required full backup if this device does not already have complete backup metadata.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if scheduler.schedule.enabled {
                    Section("Status") {
                        if let lastRun = scheduler.schedule.lastRunDate {
                            HStack {
                                Text("Last backup")
                                Spacer()
                                Text(lastRun.shortString)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let nextRun = scheduler.schedule.nextRunDate {
                            HStack {
                                Text("Next backup")
                                Spacer()
                                Text(nextRun.shortString)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let result = scheduler.schedule.lastResult {
                            HStack {
                                Text("Last result")
                                Spacer()
                                Text(result)
                                    .foregroundStyle(result == "Completed" ? .green : .orange)
                            }
                        }

                        Button("Run Now") {
                            Task { await scheduler.runNow() }
                        }
                        .disabled(
                            scheduler.isRunningScheduledBackup ||
                            (scheduler.schedule.targetUDID == nil && deviceVM.devices.count > 1)
                        )
                    }

                    if !scheduler.recentLogs.isEmpty {
                        Section("Recent Log") {
                            ForEach(scheduler.recentLogs.prefix(5)) { log in
                                HStack(spacing: 6) {
                                    Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(log.success ? .green : .red)
                                    Text(log.message)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(log.date.shortString)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: scheduler.schedule.enabled) { _, _ in scheduler.updateNextRunDate() }
        .onChange(of: scheduler.schedule.frequency) { _, _ in scheduler.updateNextRunDate() }
        .onChange(of: scheduler.schedule.preferredHour) { _, _ in scheduler.updateNextRunDate() }
        .onChange(of: scheduler.schedule.preferredMinute) { _, _ in scheduler.updateNextRunDate() }
        .onAppear { scheduler.attachBackupViewModel(backupVM) }
    }
}
