#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PurchaseState {
    Unavailable,
    Locked,
    Unlocked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpgradeCtaTarget {
    AppStoreAppPage,
    InAppPurchase,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProMonitorCapabilities {
    pub pro_available: bool,
    pub pro_enabled: bool,
    pub purchase_state: PurchaseState,
    pub upgrade_cta_target: UpgradeCtaTarget,
}

impl Default for ProMonitorCapabilities {
    fn default() -> Self {
        Self {
            pro_available: false,
            pro_enabled: false,
            purchase_state: PurchaseState::Unavailable,
            upgrade_cta_target: UpgradeCtaTarget::AppStoreAppPage,
        }
    }
}

pub trait ProMonitorApi: Send + Sync {
    fn capabilities(&self) -> ProMonitorCapabilities;
}

pub struct NoProMonitor;

impl ProMonitorApi for NoProMonitor {
    fn capabilities(&self) -> ProMonitorCapabilities {
        ProMonitorCapabilities::default()
    }
}
