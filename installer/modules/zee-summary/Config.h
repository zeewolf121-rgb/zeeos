/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * zee-summary (P4-6, #178, ADR-0003): the model behind zee-summary.qml.
 */
#ifndef ZEE_SUMMARY_CONFIG_H
#define ZEE_SUMMARY_CONFIG_H

#include <QObject>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

class Config : public QObject
{
    Q_OBJECT
    /// The mandatory "I have a backup" checkbox. Install stays disabled while it is false.
    Q_PROPERTY( bool backupConfirmed READ backupConfirmed WRITE setBackupConfirmed NOTIFY backupConfirmedChanged )
    /// False when a preset sets the checkbox and marks it read-only (unattended install, P4-9).
    Q_PROPERTY( bool backupEditable READ backupEditable CONSTANT )
    /// One entry per disk: { "disk": "/dev/sda" or "", "changes": [ "...", ... ] }.
    Q_PROPERTY( QVariantList disks READ disks NOTIFY disksChanged )
    Q_PROPERTY( bool hasChanges READ hasChanges NOTIFY disksChanged )

public:
    explicit Config( QObject* parent = nullptr );

    void setConfigurationMap( const QVariantMap& map );

    bool backupConfirmed() const { return m_backupConfirmed; }
    void setBackupConfirmed( bool confirmed );
    bool backupEditable() const { return m_backupEditable; }
    QVariantList disks() const { return m_disks; }
    bool hasChanges() const { return !m_disks.isEmpty(); }

    /// Next ("Install") is enabled only with a confirmed backup and a non-empty plan.
    bool canInstall() const { return m_backupConfirmed && hasChanges(); }

    /// Rebuilds the per-disk list from the job descriptions of the steps before this page and
    /// resets the checkbox, so a changed plan has to be confirmed again.
    void refresh( const QStringList& jobDescriptions );

signals:
    void backupConfirmedChanged( bool confirmed );
    void disksChanged();

private:
    bool m_backupConfirmed = false;
    bool m_presetConfirmed = false;
    bool m_backupEditable = true;
    QVariantList m_disks;
};

#endif
