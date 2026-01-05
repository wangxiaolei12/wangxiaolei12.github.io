# 解决GitHub Pages 404问题

## 问题诊断
- ❌ 仓库 `xiaolei-wang/xiaolei-wang.github.io` 不存在
- ❌ GitHub Pages无法访问

## 解决步骤

### 步骤1：确认GitHub用户名
```bash
# 检查你的真实GitHub用户名
# 访问 https://github.com/settings/profile
```

### 步骤2：创建正确的仓库
1. 登录GitHub
2. 点击右上角 "+" → "New repository"
3. 仓库名必须是：`你的用户名.github.io`
4. 设为Public
5. 不要勾选任何初始化选项
6. 点击"Create repository"

### 步骤3：使用正确用户名部署
```bash
cd xiaolei-blog

# 使用你的真实GitHub用户名
./deploy-fix.sh your-real-username

# 推送到GitHub
git push -u origin main
```

### 步骤4：启用GitHub Pages
1. 进入仓库设置：`https://github.com/你的用户名/你的用户名.github.io/settings/pages`
2. Source选择："Deploy from a branch"
3. Branch选择："main"
4. Folder选择："/ (root)"
5. 点击Save

### 步骤5：等待部署
- GitHub Pages需要几分钟时间部署
- 访问：`https://你的用户名.github.io`

## 常见问题

### 如果仍然404：
1. 检查仓库名是否正确（必须是 username.github.io）
2. 确认仓库是Public的
3. 检查GitHub Pages设置是否正确
4. 等待5-10分钟让GitHub处理

### 如果想使用xiaolei-wang用户名：
1. 注册GitHub账号：xiaolei-wang
2. 或者修改现有账号用户名为xiaolei-wang

## 快速测试
```bash
# 检查仓库是否存在
curl -s "https://api.github.com/repos/你的用户名/你的用户名.github.io"

# 检查网站状态
curl -s -o /dev/null -w "%{http_code}" https://你的用户名.github.io
```
